import 'dart:async';

import 'audio_cache_files.dart';
import 'log_service.dart';
import 'remote_asset_cache.dart';
import 'resumable_file_transfer.dart';

class AudioCacheRequest {
  const AudioCacheRequest({required this.uri, required this.hash});

  final Uri uri;
  final String hash;
}

/// Saves complete audio files independently of the player's network requests.
class AudioCacheDownloader {
  AudioCacheDownloader({
    required AudioCacheFiles files,
    ResumableFileTransfer? transfer,
    Future<String?> Function(String hash)? resolveExistingFile,
    Map<String, String> Function()? headersProvider,
    this.onCacheCompleted,
    void Function(String message)? logger,
  }) : _files = files,
       _transfer = transfer ?? ResumableFileTransfer(),
       _resolveExistingFile = resolveExistingFile ?? files.completedPath,
       _headersProvider = headersProvider ?? (() => const {}),
       _logger = logger ?? LogService.instance.captureOutput {
    _instances.add(this);
  }

  final AudioCacheFiles _files;
  final ResumableFileTransfer _transfer;
  final Future<String?> Function(String hash) _resolveExistingFile;
  final Map<String, String> Function() _headersProvider;
  final FutureOr<void> Function()? onCacheCompleted;
  final void Function(String message) _logger;
  static final Set<AudioCacheDownloader> _instances = {};

  _AudioCacheDownload? _active;
  Future<void> _tail = Future.value();
  bool _disposed = false;

  Future<bool> setTarget(AudioCacheRequest? request) {
    if (_disposed) return Future.value(false);
    final previous = _active;
    if (request != null &&
        previous != null &&
        previous.request.hash == request.hash &&
        previous.request.uri == request.uri &&
        !previous.cancellation.isCancelled) {
      return previous.future;
    }

    previous?.cancellation.cancel();
    if (request == null) {
      return _tail.then((_) => false);
    }

    final operation = _AudioCacheDownload(request);
    _active = operation;
    operation.future = _downloadAfter(_tail, operation);
    _tail = operation.future.then<void>((_) {});
    return operation.future;
  }

  Future<bool> _downloadAfter(
    Future<void> previous,
    _AudioCacheDownload operation,
  ) async {
    await previous;
    try {
      if (_disposed || operation.cancellation.isCancelled) return false;
      final request = operation.request;
      if (await _resolveExistingFile(request.hash) != null) return true;
      if (operation.cancellation.isCancelled) return false;

      final partial = await _files.partialFile(request.hash);
      final lease = AudioCacheFiles.holdCacheFile(partial.path);
      try {
        final result = await _transfer.download(
          uri: request.uri,
          partialFile: partial,
          cancellation: operation.cancellation,
          headers: _headersProvider(),
        );
        if (operation.cancellation.isCancelled) return false;
        final completed = await _files.finalize(
          request.hash,
          expectedSize: result.totalBytes,
        );
        if (completed && onCacheCompleted != null) {
          unawaited(
            Future<void>.sync(onCacheCompleted!).catchError((Object error) {
              _logger('[AudioCache] 缓存维护失败: $error');
            }),
          );
        }
        return completed;
      } finally {
        lease.release();
      }
    } catch (error) {
      if (!operation.cancellation.isCancelled) {
        _logger('[AudioCache] 后台缓存失败: ${operation.request.hash} - $error');
      }
      return false;
    } finally {
      if (identical(_active, operation)) _active = null;
    }
  }

  static Future<void> cancelAll() async {
    await Future.wait(
      List<AudioCacheDownloader>.of(
        _instances,
      ).map((downloader) => downloader.setTarget(null)),
    );
  }

  Future<void> invalidate(String hash) {
    final operation = _active;
    if (operation?.request.hash == hash) {
      operation!.cancellation.cancel();
    }
    // A replacement download must wait until stale files have been removed.
    final invalidating = _tail.then((_) => _files.invalidate(hash));
    _tail = invalidating.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return invalidating;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _active?.cancellation.cancel();
    await _tail;
    _instances.remove(this);
  }
}

class _AudioCacheDownload {
  _AudioCacheDownload(this.request);

  final AudioCacheRequest request;
  final RemoteAssetCancellation cancellation = RemoteAssetCancellation();
  late final Future<bool> future;
}
