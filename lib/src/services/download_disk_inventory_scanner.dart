import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../models/scan_models.dart';
import 'local_work_metadata_service.dart';

class DownloadDiskFile {
  const DownloadDiskFile({
    required this.absolutePath,
    required this.relativePath,
    required this.size,
    required this.modifiedAt,
    required this.isUserFile,
  });

  final String absolutePath;
  final String relativePath;
  final int size;
  final DateTime modifiedAt;
  final bool isUserFile;

  factory DownloadDiskFile.fromMessage(Map<Object?, Object?> message) {
    return DownloadDiskFile(
      absolutePath: message['absolutePath']! as String,
      relativePath: message['relativePath']! as String,
      size: message['size']! as int,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(
        message['modifiedAtMs']! as int,
      ),
      isUserFile: message['isUserFile']! as bool,
    );
  }
}

class DownloadDiskInventory {
  const DownloadDiskInventory(this.filesByWorkId);

  final Map<int, List<DownloadDiskFile>> filesByWorkId;

  List<DownloadDiskFile> filesFor(int workId) {
    return filesByWorkId[workId] ?? const <DownloadDiskFile>[];
  }

  Map<String, DownloadDiskFile> userFilesByRelativePath(int workId) {
    return {
      for (final file in filesFor(workId))
        if (file.isUserFile) file.relativePath: file,
    };
  }
}

/// Builds a reusable download-directory inventory outside the UI isolate.
class DownloadDiskInventoryScanner {
  const DownloadDiskInventoryScanner();

  Future<ScanResult<DownloadDiskInventory>> scan({
    required ScanRequest request,
    required Map<int, String> workDirectoryPaths,
    ScanCancellationToken? cancellationToken,
    void Function(ScanProgress progress)? onProgress,
  }) async {
    cancellationToken?.throwIfCancelled();
    final stopwatch = Stopwatch()..start();
    final receivePort = ReceivePort();
    final completer = Completer<_DownloadInventoryWorkerResult>();
    late final Isolate isolate;

    final subscription = receivePort.listen((message) {
      if (message == null) {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('Download scan isolate exited without a result'),
          );
        }
        return;
      }
      if (message is! Map<Object?, Object?>) return;

      switch (message['type']) {
        case 'progress':
          onProgress?.call(
            ScanProgress(
              request: request,
              scannedEntries: message['scannedEntries']! as int,
              currentPath: message['currentPath'] as String?,
            ),
          );
        case 'result':
          if (completer.isCompleted) return;
          final rawFiles = message['filesByWorkId']! as Map<Object?, Object?>;
          final filesByWorkId = <int, List<DownloadDiskFile>>{};
          for (final entry in rawFiles.entries) {
            filesByWorkId[entry.key! as int] = (entry.value! as List<Object?>)
                .cast<Map<Object?, Object?>>()
                .map(DownloadDiskFile.fromMessage)
                .toList(growable: false);
          }
          completer.complete(
            _DownloadInventoryWorkerResult(
              inventory: DownloadDiskInventory(filesByWorkId),
              scannedEntries: message['scannedEntries']! as int,
            ),
          );
        case 'error':
          if (!completer.isCompleted) {
            completer.completeError(
              StateError(
                message['error']?.toString() ?? 'Download scan failed',
              ),
            );
          }
      }
    });

    isolate = await Isolate.spawn<Map<String, Object?>>(
      _downloadInventoryWorker,
      {
        'sendPort': receivePort.sendPort,
        'workDirectoryPaths': workDirectoryPaths,
      },
      onExit: receivePort.sendPort,
    );

    var cancelled = false;
    unawaited(
      cancellationToken?.whenCancelled.then((_) {
        if (completer.isCompleted) return;
        cancelled = true;
        isolate.kill(priority: Isolate.immediate);
        completer.completeError(const ScanCancelledException());
      }),
    );

    try {
      final workerResult = await completer.future;
      cancellationToken?.throwIfCancelled();
      stopwatch.stop();
      onProgress?.call(
        ScanProgress(
          request: request,
          scannedEntries: workerResult.scannedEntries,
        ),
      );
      return ScanResult(
        request: request,
        value: workerResult.inventory,
        scannedEntries: workerResult.scannedEntries,
        duration: stopwatch.elapsed,
      );
    } finally {
      if (!cancelled) isolate.kill(priority: Isolate.immediate);
      await subscription.cancel();
      receivePort.close();
    }
  }
}

void _downloadInventoryWorker(Map<String, Object?> arguments) {
  final sendPort = arguments['sendPort']! as SendPort;
  final rawPaths = arguments['workDirectoryPaths']! as Map<Object?, Object?>;
  final filesByWorkId = <int, List<Map<String, Object?>>>{};
  var scannedEntries = 0;

  try {
    for (final entry in rawPaths.entries) {
      final workId = entry.key! as int;
      final workPath = entry.value! as String;
      final files = <Map<String, Object?>>[];
      filesByWorkId[workId] = files;

      void scanDirectory(Directory directory, String parentRelativePath) {
        List<FileSystemEntity> entities;
        try {
          entities = directory.listSync(followLinks: false);
        } on FileSystemException {
          return;
        }

        for (final entity in entities) {
          scannedEntries++;
          if (scannedEntries % 128 == 0) {
            sendPort.send({
              'type': 'progress',
              'scannedEntries': scannedEntries,
              'currentPath': entity.path,
            });
          }

          final name = p.basename(entity.path);
          if (name.startsWith('.') || name.endsWith('.downloading')) continue;
          final relativePath = parentRelativePath.isEmpty
              ? name
              : '$parentRelativePath/$name';

          if (entity is Directory) {
            scanDirectory(entity, relativePath);
            continue;
          }
          if (entity is! File) continue;

          try {
            final stat = entity.statSync();
            files.add({
              'absolutePath': entity.path,
              'relativePath': relativePath.replaceAll('\\', '/'),
              'size': stat.size,
              'modifiedAtMs': stat.modified.millisecondsSinceEpoch,
              'isUserFile': !LocalWorkMetadataService.shouldSkipMetadataFile(
                name,
                isRoot: parentRelativePath.isEmpty,
              ),
            });
          } on FileSystemException {
            // Ignore files removed during the scan.
          }
        }
      }

      scanDirectory(Directory(workPath), '');
    }

    sendPort.send({
      'type': 'result',
      'filesByWorkId': filesByWorkId,
      'scannedEntries': scannedEntries,
    });
  } catch (error) {
    sendPort.send({'type': 'error', 'error': error.toString()});
  }
}

class _DownloadInventoryWorkerResult {
  const _DownloadInventoryWorkerResult({
    required this.inventory,
    required this.scannedEntries,
  });

  final DownloadDiskInventory inventory;
  final int scannedEntries;
}
