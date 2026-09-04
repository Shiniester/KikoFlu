import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

const String cacheFileBackupSuffix = '.replace-backup';

final Map<String, int> _activePaths = <String, int>{};
final Map<String, Future<void>> _transactionTails = <String, Future<void>>{};

bool isCacheFileTransactionActive(String path) {
  return _activePaths.containsKey(p.normalize(path));
}

File cacheFileBackup(File destination) {
  return File('${destination.path}$cacheFileBackupSuffix');
}

/// Restores the last valid file after an interrupted Windows-style swap.
Future<void> recoverCacheFileReplacement(File destination) async {
  await _serializeForDestination(destination, () async {
    final backup = cacheFileBackup(destination);
    _mark(destination.path);
    _mark(backup.path);
    try {
      await _recoverMarkedReplacement(destination, backup);
    } finally {
      _unmark(backup.path);
      _unmark(destination.path);
    }
  });
}

/// Replaces [destination] without deleting the previous valid file first.
///
/// POSIX rename replaces atomically. Platforms that reject replacing an
/// existing path use a recoverable backup swap; readers call
/// [recoverCacheFileReplacement] before opening the destination.
Future<File> replaceCacheFile(File source, File destination) async {
  return _serializeForDestination(destination, () async {
    final backup = cacheFileBackup(destination);
    for (final path in [source.path, destination.path, backup.path]) {
      _mark(path);
    }
    try {
      await _recoverMarkedReplacement(destination, backup);
      if (!await destination.exists()) {
        return source.rename(destination.path);
      }

      try {
        return await source.rename(destination.path);
      } on FileSystemException {
        // Windows does not replace an existing file with File.rename. Preserve
        // the old file under a deterministic recovery name before the swap.
      }

      await destination.rename(backup.path);
      try {
        final replacement = await source.rename(destination.path);
        try {
          await backup.delete();
        } on FileSystemException {
          // A leftover backup is harmless and will be removed by recovery.
        }
        return replacement;
      } catch (_) {
        if (!await destination.exists() && await backup.exists()) {
          await backup.rename(destination.path);
        }
        rethrow;
      }
    } finally {
      for (final path in [backup.path, destination.path, source.path]) {
        _unmark(path);
      }
    }
  });
}

Future<T> _serializeForDestination<T>(
  File destination,
  Future<T> Function() action,
) {
  final key = p.normalize(destination.absolute.path);
  final previous = _transactionTails[key] ?? Future<void>.value();
  final release = Completer<void>();
  final tail = release.future;
  _transactionTails[key] = tail;

  return previous.then((_) async {
    try {
      return await action();
    } finally {
      release.complete();
      if (identical(_transactionTails[key], tail)) {
        _transactionTails.remove(key);
      }
    }
  });
}

Future<void> _recoverMarkedReplacement(File destination, File backup) async {
  final destinationExists = await destination.exists();
  final backupExists = await backup.exists();
  if (!backupExists) return;
  if (destinationExists) {
    await backup.delete();
  } else {
    await backup.rename(destination.path);
  }
}

void _mark(String path) {
  final normalized = p.normalize(path);
  _activePaths.update(normalized, (count) => count + 1, ifAbsent: () => 1);
}

void _unmark(String path) {
  final normalized = p.normalize(path);
  final count = _activePaths[normalized];
  if (count == null || count <= 1) {
    _activePaths.remove(normalized);
  } else {
    _activePaths[normalized] = count - 1;
  }
}
