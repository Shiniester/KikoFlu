import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../models/scan_models.dart';
import 'subtitle_matching.dart';

class SubtitleScanEntry {
  const SubtitleScanEntry({
    required this.fileName,
    required this.relativePath,
    required this.category,
    required this.fileSize,
    required this.modifiedAt,
    required this.normalizedName,
    this.workId,
  });

  final String fileName;
  final String relativePath;
  final String category;
  final int? workId;
  final int fileSize;
  final String modifiedAt;
  final String normalizedName;

  factory SubtitleScanEntry.fromMessage(Map<Object?, Object?> message) {
    return SubtitleScanEntry(
      fileName: message['fileName']! as String,
      relativePath: message['relativePath']! as String,
      category: message['category']! as String,
      workId: message['workId'] as int?,
      fileSize: message['fileSize']! as int,
      modifiedAt: message['modifiedAt']! as String,
      normalizedName: message['normalizedName']! as String,
    );
  }
}

/// Scans subtitle metadata in a worker isolate and streams coarse progress.
class SubtitleDirectoryScanner {
  const SubtitleDirectoryScanner();

  Future<ScanResult<List<SubtitleScanEntry>>> scan({
    required ScanRequest request,
    String? directoryPath,
    ScanCancellationToken? cancellationToken,
    void Function(ScanProgress progress)? onProgress,
  }) async {
    cancellationToken?.throwIfCancelled();
    final stopwatch = Stopwatch()..start();
    final receivePort = ReceivePort();
    final completer = Completer<_SubtitleWorkerResult>();
    final records = <SubtitleScanEntry>[];
    late final Isolate isolate;

    final subscription = receivePort.listen((message) {
      if (message == null) {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('Subtitle scan isolate exited without a result'),
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
        case 'records':
          final batch = (message['records']! as List<Object?>)
              .cast<Map<Object?, Object?>>();
          records.addAll(batch.map(SubtitleScanEntry.fromMessage));
        case 'result':
          if (completer.isCompleted) return;
          completer.complete(
            _SubtitleWorkerResult(
              records: List<SubtitleScanEntry>.unmodifiable(records),
              scannedEntries: message['scannedEntries']! as int,
            ),
          );
        case 'error':
          if (!completer.isCompleted) {
            completer.completeError(
              StateError(
                message['error']?.toString() ?? 'Subtitle scan failed',
              ),
            );
          }
      }
    });

    isolate = await Isolate.spawn<Map<String, Object?>>(_subtitleScanWorker, {
      'sendPort': receivePort.sendPort,
      'rootPath': request.rootPath,
      'directoryPath': directoryPath ?? request.rootPath,
    }, onExit: receivePort.sendPort);

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
        value: workerResult.records,
        scannedEntries: workerResult.scannedEntries,
        duration: stopwatch.elapsed,
      );
    } finally {
      if (!cancelled) {
        isolate.kill(priority: Isolate.immediate);
      }
      await subscription.cancel();
      receivePort.close();
    }
  }
}

void _subtitleScanWorker(Map<String, Object?> arguments) {
  final sendPort = arguments['sendPort']! as SendPort;
  final rootPath = arguments['rootPath']! as String;
  final directoryPath = arguments['directoryPath']! as String;
  var records = <Map<String, Object?>>[];
  var scannedEntries = 0;

  try {
    void flushRecords() {
      if (records.isEmpty) return;
      final batch = records;
      records = <Map<String, Object?>>[];
      sendPort.send({'type': 'records', 'records': batch});
    }

    void scanDirectory(Directory directory) {
      if (directory.path.length > 240) return;

      List<FileSystemEntity> entities;
      try {
        entities = directory.listSync(followLinks: false);
      } on FileSystemException {
        return;
      }

      for (final entity in entities) {
        scannedEntries++;
        if (scannedEntries % 64 == 0) {
          sendPort.send({
            'type': 'progress',
            'scannedEntries': scannedEntries,
            'currentPath': entity.path,
          });
        }

        if (entity is Directory) {
          if (p.basename(entity.path).startsWith('.')) continue;
          scanDirectory(entity);
          continue;
        }
        if (entity is! File || !_isSubtitlePath(entity.path)) continue;

        try {
          final stat = entity.statSync();
          final fileName = p.basename(entity.path);
          final relativePath = p
              .relative(entity.path, from: rootPath)
              .replaceAll('\\', '/');
          final category = _extractCategory(relativePath);
          records.add({
            'fileName': fileName,
            'relativePath': relativePath,
            'category': category,
            'workId': _extractWorkId(relativePath),
            'fileSize': stat.size,
            'modifiedAt': stat.modified.toIso8601String(),
            'normalizedName': _computeNormalizedName(fileName),
          });
          // Bound both the worker heap and the cross-isolate copy. The old
          // implementation retained all 10,000 maps until the final send,
          // temporarily overlapping them with their receiving-side copies.
          if (records.length >= 128) flushRecords();
        } on FileSystemException {
          // The file may have moved while scanning. It will be picked up next
          // time instead of aborting the complete inventory.
        }
      }
    }

    scanDirectory(Directory(directoryPath));
    flushRecords();
    sendPort.send({'type': 'result', 'scannedEntries': scannedEntries});
  } catch (error) {
    sendPort.send({'type': 'error', 'error': error.toString()});
  }
}

const _subtitleExtensions = {
  '.vtt',
  '.srt',
  '.lrc',
  '.txt',
  '.ass',
  '.ssa',
  '.sub',
  '.idx',
  '.sbv',
  '.dfxp',
  '.ttml',
};

bool _isSubtitlePath(String path) {
  return _subtitleExtensions.contains(p.extension(path).toLowerCase());
}

String _extractCategory(String relativePath) {
  final firstSlash = relativePath.indexOf('/');
  return firstSlash > 0 ? relativePath.substring(0, firstSlash) : '';
}

final _workIdRegex = RegExp(r'[RrBbVv][Jj]0*(\d+)');

int? _extractWorkId(String relativePath) {
  final parts = relativePath.split('/');
  if (parts.length < 2) return null;
  final match = _workIdRegex.firstMatch(parts[1]);
  return match == null ? null : int.tryParse(match.group(1)!);
}

String _computeNormalizedName(String fileName) {
  const textExtensions = ['.vtt', '.srt', '.txt', '.lrc'];
  var baseName = fileName.toLowerCase();
  for (final extension in textExtensions) {
    if (!baseName.endsWith(extension)) continue;
    baseName = baseName.substring(0, baseName.length - extension.length);
    break;
  }
  baseName = SubtitleMatcher.removeAudioExtension(baseName);
  return SubtitleMatcher.normalizeForMatching(baseName);
}

class _SubtitleWorkerResult {
  const _SubtitleWorkerResult({
    required this.records,
    required this.scannedEntries,
  });

  final List<SubtitleScanEntry> records;
  final int scannedEntries;
}
