import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/cache_file_transaction.dart';
import '../services/http_response_stream.dart';
import '../services/remote_asset_cache.dart';
import '../services/resumable_file_transfer.dart';
import '../services/shared_http_client.dart';
import 'missav_client.dart';
import 'video_download_task.dart';
import 'video_library.dart';
import 'video_models.dart';

class VideoDownloads extends ChangeNotifier {
  VideoDownloads({
    required this.client,
    required this.library,
    Directory? rootDirectory,
    SharedPreferences? preferences,
    RemoteAssetTransport? transport,
  }) : _providedRoot = rootDirectory,
       _providedPreferences = preferences,
       _transport = transport ?? _VideoAssetTransport() {
    _transfer = ResumableFileTransfer(transport: _transport);
  }

  static const _tasksKey = 'video_download_tasks_v1';
  static const _playlistLimit = 2 * 1024 * 1024;

  final MissavClient client;
  final VideoLibrary library;
  final Directory? _providedRoot;
  final SharedPreferences? _providedPreferences;
  final RemoteAssetTransport _transport;
  late final ResumableFileTransfer _transfer;
  final List<VideoDownloadTask> _tasks = [];
  final Set<String> _deleting = {};
  SharedPreferences? _preferences;
  Future<Directory>? _rootFuture;
  Future<void>? _initializing;
  Future<void>? _running;
  Future<void> _writeTail = Future<void>.value();
  _VideoDownloadOperation? _active;
  Directory? _resolvedRoot;
  bool _disposed = false;

  Future<void> initialize() {
    final initializing = _initializing;
    if (initializing != null) return initializing;
    if (_preferences != null && _resolvedRoot != null) return Future.value();
    return _initializing = _restore().whenComplete(() => _initializing = null);
  }

  List<VideoDownloadTask> get tasks => List.unmodifiable(_tasks);

  VideoDownloadTask? forVideo(String videoId) {
    for (final task in _tasks) {
      if (task.id == videoId) return task;
    }
    return null;
  }

  Future<VideoDownloadTask> add(VideoItem video, VideoStream stream) async {
    await initialize();
    final existing = forVideo(video.id);
    if (existing != null) return existing;

    final isHls = _isHlsStream(stream);
    final directory = _taskDirectory(video.id);
    final task = VideoDownloadTask(
      id: video.id,
      video: video,
      quality: stream.label,
      isHls: isHls,
      status: VideoDownloadStatus.queued,
      localPath: p.join(directory.path, isHls ? 'index.m3u8' : 'video.mp4'),
    );
    _tasks.add(task);
    await _persist();
    _notify();
    _startQueue();
    return task;
  }

  Future<void> pause(String videoId) async {
    await initialize();
    final task = forVideo(videoId);
    if (task == null || task.status == VideoDownloadStatus.completed) return;

    _replaceTask(task.copyWith(status: VideoDownloadStatus.paused));
    final operation = _active;
    if (operation?.id == videoId) operation!.cancellation.cancel();
    try {
      await _persist();
    } finally {
      _notify();
      if (operation?.id == videoId) await operation!.done.future;
    }
  }

  Future<void> resume(String videoId) async {
    await initialize();
    if (_deleting.contains(videoId)) return;
    final task = forVideo(videoId);
    if (task == null || task.status == VideoDownloadStatus.completed) return;
    if (_active?.id == videoId &&
        task.status == VideoDownloadStatus.downloading) {
      return;
    }
    _replaceTask(
      task.copyWith(status: VideoDownloadStatus.queued, clearError: true),
    );
    await _persist();
    _notify();
    _startQueue();
  }

  Future<void> retry(String videoId) => resume(videoId);

  Future<void> remove(String videoId) async {
    await initialize();
    final task = forVideo(videoId);
    if (task == null || !_deleting.add(videoId)) return;

    try {
      final operation = _active;
      if (operation?.id == videoId) {
        _replaceTask(task.copyWith(status: VideoDownloadStatus.paused));
        operation!.cancellation.cancel();
        await operation.done.future;
      }
      final directory = _taskDirectory(videoId);
      if (await directory.exists()) await directory.delete(recursive: true);
      _tasks.removeWhere((value) => value.id == videoId);
      await _persist();
      _notify();
    } finally {
      _deleting.remove(videoId);
    }
  }

  Future<void> _restore() async {
    await library.initialize();
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    _preferences = preferences;
    await _root();

    final saved = preferences.getString(_tasksKey);
    if (saved != null) {
      try {
        final decoded = jsonDecode(saved);
        if (decoded is List) {
          for (final value in decoded) {
            if (value is! Map) continue;
            try {
              var task = VideoDownloadTask.fromJson(
                Map<String, dynamic>.from(value),
              );
              if (task.id != task.video.id ||
                  _tasks.any((existing) => existing.id == task.id)) {
                continue;
              }
              task = task.copyWith(
                localPath: _localPath(task),
                status: switch (task.status) {
                  VideoDownloadStatus.queued ||
                  VideoDownloadStatus.downloading => VideoDownloadStatus.paused,
                  _ => task.status,
                },
              );
              if (task.status == VideoDownloadStatus.completed &&
                  !await _isComplete(task)) {
                task = task.copyWith(
                  status: VideoDownloadStatus.failed,
                  error: 'The downloaded video file is missing or incomplete.',
                );
              }
              _tasks.add(task);
            } on Object {
              // One malformed task must not prevent the remaining tasks restoring.
            }
          }
        }
      } on FormatException {
        // A malformed task list is ignored and replaced on the next change.
      }
    }
    if (_tasks.isNotEmpty) await _persist();
    _notify();
  }

  void _startQueue() {
    if (_disposed || _running != null) return;
    _running = _drainQueue().whenComplete(() {
      _running = null;
      if (!_disposed && _hasEligibleQueuedTask()) _startQueue();
    });
  }

  Future<void> _drainQueue() async {
    while (!_disposed) {
      VideoDownloadTask? task;
      for (final candidate in _tasks) {
        if (_isEligibleQueued(candidate)) {
          task = candidate;
          break;
        }
      }
      if (task == null) return;

      final operation = _VideoDownloadOperation(task.id);
      _active = operation;
      _replaceTask(
        task.copyWith(
          status: VideoDownloadStatus.downloading,
          progress: 0,
          clearError: true,
        ),
      );
      try {
        await _persist();
        _notify();
        await _download(forVideo(task.id)!, operation);
        if (_canContinue(operation)) {
          _replaceTask(
            forVideo(task.id)!.copyWith(
              status: VideoDownloadStatus.completed,
              progress: 1,
              clearError: true,
            ),
          );
        }
      } catch (error) {
        final current = forVideo(task.id);
        if (current != null && !_deleting.contains(task.id)) {
          if (operation.cancellation.isCancelled ||
              current.status == VideoDownloadStatus.paused) {
            if (current.status == VideoDownloadStatus.downloading) {
              _replaceTask(
                current.copyWith(status: VideoDownloadStatus.paused),
              );
            }
          } else if (identical(_active, operation)) {
            _replaceTask(
              current.copyWith(
                status: VideoDownloadStatus.failed,
                error: _safeFailure(error),
              ),
            );
          }
        }
      } finally {
        try {
          await _persist();
        } catch (_) {
          // Keep the operation settled if local task storage fails.
        } finally {
          if (identical(_active, operation)) _active = null;
          operation.done.complete();
          _notify();
        }
      }
    }
  }

  Future<void> _download(
    VideoDownloadTask task,
    _VideoDownloadOperation operation,
  ) async {
    _ensureCurrent(operation);
    final details = await client.details(
      task.video,
      includeAccountState: false,
    );
    _ensureCurrent(operation);
    final stream = _selectStream(details, task.quality);
    if (stream == null) {
      throw const _VideoDownloadException(
        'The selected video quality is no longer available.',
      );
    }
    if (_isHlsStream(stream) != task.isHls) {
      throw const _VideoDownloadException(
        'The selected video format changed and cannot be resumed.',
      );
    }

    final uri = _requireHttpUri(Uri.parse(stream.url));
    final directory = _taskDirectory(task.id);
    await directory.create(recursive: true);
    final headers = _headersFor(task.video, uri, stream.headers);
    if (task.isHls) {
      await _downloadHls(task, uri, headers, directory, operation);
    } else {
      await _downloadMp4(task, uri, headers, operation);
    }
  }

  Future<void> _downloadMp4(
    VideoDownloadTask task,
    Uri uri,
    Map<String, String> headers,
    _VideoDownloadOperation operation,
  ) async {
    final destination = File(task.localPath!);
    final partial = File('${destination.path}.part');
    await _transfer.download(
      uri: uri,
      partialFile: partial,
      cancellation: operation.cancellation,
      headers: headers,
      expectedAudio: true,
      onProgress: (received, total) {
        if (total == null || total <= 0) return;
        _reportProgress(
          operation,
          received / total,
          persistWhenChangedBy: 0.02,
        );
      },
    );
    _ensureCurrent(operation);
    if (!await _isMp4(partial)) {
      if (await partial.exists()) await partial.delete();
      throw const _VideoDownloadException(
        'This video format is not supported for offline playback.',
      );
    }
    _ensureCurrent(operation);
    await replaceCacheFile(partial, destination);
  }

  Future<void> _downloadHls(
    VideoDownloadTask task,
    Uri uri,
    Map<String, String> headers,
    Directory directory,
    _VideoDownloadOperation operation,
  ) async {
    final playlist = await _resolvePlaylist(uri, headers, operation, 0);
    _ensureCurrent(operation);
    if (!playlist.lines.any((line) => line.trim() == '#EXT-X-ENDLIST')) {
      throw const _VideoDownloadException(
        'Live HLS streams are not supported for offline playback.',
      );
    }
    if (playlist.lines.any(
      (line) => line.trim().startsWith('#EXT-X-BYTERANGE'),
    )) {
      throw const _VideoDownloadException(
        'HLS byte-range streams are not supported for offline playback.',
      );
    }

    final outputLines = <String>[];
    final localKeys = <String, String>{};
    final localMaps = <String, String>{};
    final localSegments = <String, String>{};
    final resourceCount = _hlsResourceCount(playlist.lines);
    if (resourceCount == 0) {
      throw const _VideoDownloadException(
        'The HLS playlist contains no media.',
      );
    }
    var completedResources = 0;
    var encrypted = false;
    var segmentIndex = 0;
    var keyIndex = 0;
    var mapIndex = 0;

    for (final rawLine in playlist.lines) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        outputLines.add(rawLine);
        continue;
      }
      if (line.startsWith('#EXT-X-DEFINE:')) {
        throw const _VideoDownloadException(
          'HLS variable references are not supported for offline playback.',
        );
      }
      if (line.startsWith('#EXT-X-PART:') ||
          line.startsWith('#EXT-X-PRELOAD-HINT:') ||
          line.startsWith('#EXT-X-RENDITION-REPORT:') ||
          line.startsWith('#EXT-X-SERVER-CONTROL:') ||
          line.startsWith('#EXT-X-SKIP:')) {
        throw const _VideoDownloadException(
          'Low-latency or live HLS is not supported for offline playback.',
        );
      }
      if (line.startsWith('#EXT-X-KEY:')) {
        final attributes = _parseAttributes(
          line.substring('#EXT-X-KEY:'.length),
        );
        final method = attributes['METHOD']?.toUpperCase();
        if (method == null || (method != 'NONE' && method != 'AES-128')) {
          throw const _VideoDownloadException(
            'This HLS encryption method is not supported for offline playback.',
          );
        }
        if (attributes['KEYFORMAT'] != null &&
            attributes['KEYFORMAT']!.toLowerCase() != 'identity') {
          throw const _VideoDownloadException(
            'This HLS key format is not supported for offline playback.',
          );
        }
        final keyUri = attributes['URI'];
        if (method == 'NONE') {
          if (keyUri != null) {
            throw const _VideoDownloadException(
              'The HLS encryption key declaration is invalid.',
            );
          }
          encrypted = false;
          outputLines.add(rawLine);
          continue;
        }
        encrypted = true;
        if (keyUri == null) {
          throw const _VideoDownloadException(
            'The HLS encryption key is missing.',
          );
        }
        final resolved = _resolveHttpUri(playlist.baseUri, keyUri);
        final local = localKeys.putIfAbsent(
          resolved.toString(),
          () => 'keys/${(keyIndex++).toString().padLeft(4, '0')}.key',
        );
        await _downloadHlsResource(
          task,
          resolved,
          File(p.join(directory.path, local)),
          headers,
          operation,
          kind: _HlsResourceKind.key,
          encrypted: false,
          completedResources: completedResources,
          resourceCount: resourceCount,
        );
        completedResources++;
        _reportProgress(
          operation,
          completedResources / resourceCount,
          persistWhenChangedBy: 0.02,
        );
        outputLines.add(_replaceUriAttribute(rawLine, local));
        continue;
      }
      if (line.startsWith('#EXT-X-MAP:')) {
        final attributes = _parseAttributes(
          line.substring('#EXT-X-MAP:'.length),
        );
        if (attributes.containsKey('BYTERANGE')) {
          throw const _VideoDownloadException(
            'HLS byte-range maps are not supported for offline playback.',
          );
        }
        final mapUri = attributes['URI'];
        if (mapUri == null) {
          throw const _VideoDownloadException(
            'The HLS initialization map is invalid.',
          );
        }
        final resolved = _resolveHttpUri(playlist.baseUri, mapUri);
        final local = localMaps.putIfAbsent(
          resolved.toString(),
          () => 'maps/${(mapIndex++).toString().padLeft(4, '0')}.mp4',
        );
        await _downloadHlsResource(
          task,
          resolved,
          File(p.join(directory.path, local)),
          headers,
          operation,
          kind: _HlsResourceKind.map,
          encrypted: encrypted,
          completedResources: completedResources,
          resourceCount: resourceCount,
        );
        completedResources++;
        _reportProgress(
          operation,
          completedResources / resourceCount,
          persistWhenChangedBy: 0.02,
        );
        outputLines.add(_replaceUriAttribute(rawLine, local));
        continue;
      }
      if (line.startsWith('#EXT-X-')) {
        if (line.contains('URI=')) {
          throw const _VideoDownloadException(
            'This HLS playlist references an unsupported external resource.',
          );
        }
        outputLines.add(rawLine);
        continue;
      }
      if (line.startsWith('#')) {
        outputLines.add(rawLine);
        continue;
      }

      final resolved = _resolveHttpUri(playlist.baseUri, line);
      final local = localSegments.putIfAbsent(
        resolved.toString(),
        () =>
            'segments/${(segmentIndex++).toString().padLeft(6, '0')}${_segmentExtension(resolved)}',
      );
      await _downloadHlsResource(
        task,
        resolved,
        File(p.join(directory.path, local)),
        headers,
        operation,
        kind: _HlsResourceKind.segment,
        encrypted: encrypted,
        completedResources: completedResources,
        resourceCount: resourceCount,
      );
      completedResources++;
      _reportProgress(
        operation,
        completedResources / resourceCount,
        persistWhenChangedBy: 0.02,
      );
      outputLines.add(local);
    }

    _ensureCurrent(operation);
    final output = File(task.localPath!);
    final temporary = File('${output.path}.part');
    await temporary.parent.create(recursive: true);
    await temporary.writeAsString('${outputLines.join('\n')}\n', flush: true);
    _ensureCurrent(operation);
    await replaceCacheFile(temporary, output);
  }

  Future<void> _downloadHlsResource(
    VideoDownloadTask task,
    Uri uri,
    File destination,
    Map<String, String> streamHeaders,
    _VideoDownloadOperation operation, {
    required _HlsResourceKind kind,
    required bool encrypted,
    required int completedResources,
    required int resourceCount,
  }) async {
    _ensureCurrent(operation);
    if (await destination.exists() && await destination.length() > 0) return;
    final partial = File('${destination.path}.part');
    await _transfer.download(
      uri: uri,
      partialFile: partial,
      cancellation: operation.cancellation,
      headers: _headersFor(task.video, uri, streamHeaders),
      expectedAudio: true,
      onProgress: (received, total) {
        if (total == null || total <= 0) return;
        _reportProgress(
          operation,
          (completedResources + received / total) / resourceCount,
          persistWhenChangedBy: 0.02,
        );
      },
    );
    _ensureCurrent(operation);
    final valid = switch (kind) {
      _HlsResourceKind.key => await _isAesKey(partial),
      _HlsResourceKind.map =>
        encrypted
            ? await _isEncryptedHlsResource(partial)
            : await _isFmp4Init(partial),
      _HlsResourceKind.segment => await _isHlsSegment(partial, encrypted),
    };
    if (!valid) {
      if (await partial.exists()) await partial.delete();
      throw const _VideoDownloadException(
        'The source returned an invalid HLS media resource.',
      );
    }
    _ensureCurrent(operation);
    await replaceCacheFile(partial, destination);
  }

  Future<_ResolvedPlaylist> _resolvePlaylist(
    Uri uri,
    Map<String, String> headers,
    _VideoDownloadOperation operation,
    int depth,
  ) async {
    if (depth > 5) {
      throw const _VideoDownloadException(
        'The HLS master playlist is too deep.',
      );
    }
    final fetched = await _fetchText(uri, headers, operation);
    final lines = const LineSplitter().convert(fetched.text);
    if (!lines.any((line) => line.trim() == '#EXTM3U')) {
      throw const _VideoDownloadException(
        'The source did not return a valid HLS playlist.',
      );
    }

    final variants = <_HlsVariant>[];
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      final attributes = _parseAttributes(
        line.substring('#EXT-X-STREAM-INF:'.length),
      );
      String? variantUri;
      for (var next = index + 1; next < lines.length; next++) {
        final candidate = lines[next].trim();
        if (candidate.isEmpty) continue;
        if (!candidate.startsWith('#')) variantUri = candidate;
        break;
      }
      if (variantUri != null) {
        variants.add(
          _HlsVariant(
            uri: _resolveHttpUri(fetched.baseUri, variantUri),
            bandwidth:
                int.tryParse(
                  attributes['BANDWIDTH'] ??
                      attributes['AVERAGE-BANDWIDTH'] ??
                      '',
                ) ??
                0,
            audioGroup: attributes['AUDIO'],
          ),
        );
      }
    }
    if (variants.isEmpty) return _ResolvedPlaylist(fetched.baseUri, lines);
    if (lines.any((line) => line.trim().startsWith('#EXT-X-SESSION-KEY:'))) {
      throw const _VideoDownloadException(
        'HLS session keys are not supported for offline playback.',
      );
    }

    variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    final selected = variants.first;
    if (selected.audioGroup != null) {
      throw const _VideoDownloadException(
        'HLS streams with separate audio tracks are not supported offline.',
      );
    }
    return _resolvePlaylist(
      selected.uri,
      _headersForUri(uri, selected.uri, headers),
      operation,
      depth + 1,
    );
  }

  Future<_FetchedText> _fetchText(
    Uri uri,
    Map<String, String> headers,
    _VideoDownloadOperation operation,
  ) async {
    _ensureCurrent(operation);
    uri = _requireHttpUri(uri);
    final response = await _transport.open(
      RemoteAssetTransportRequest(
        uri: uri,
        headers: _headersForUri(uri, uri, headers),
        cancellation: operation.cancellation,
      ),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      throw const _VideoDownloadException('The HLS playlist request failed.');
    }
    if ((response.header(HttpHeaders.contentTypeHeader) ?? '')
        .toLowerCase()
        .contains('text/html')) {
      await response.stream.drain<void>();
      throw const _VideoDownloadException(
        'The source returned an HTML verification page.',
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      _ensureCurrent(operation);
      if (builder.length + chunk.length > _playlistLimit) {
        throw const _VideoDownloadException('The HLS playlist is too large.');
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (_looksLikeHtml(bytes)) {
      throw const _VideoDownloadException(
        'The source returned an HTML verification page.',
      );
    }
    final text = utf8.decode(bytes, allowMalformed: false);
    final finalUri = response.finalUri ?? uri;
    return _FetchedText(finalUri, text);
  }

  Future<bool> _isComplete(VideoDownloadTask task) async {
    final path = task.localPath;
    if (path == null) return false;
    if (!task.isHls) {
      final file = File(path);
      return await file.exists() && await _isMp4(file);
    }
    final playlist = File(path);
    if (!await playlist.exists()) return false;
    final directory = playlist.parent;
    final content = await playlist.readAsString();
    if (!content.contains('#EXT-X-ENDLIST')) return false;
    for (final rawLine in const LineSplitter().convert(content)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        if (line.startsWith('#EXT-X-KEY:') || line.startsWith('#EXT-X-MAP:')) {
          final attributes = _parseAttributes(
            line.substring(line.indexOf(':') + 1),
          );
          if (line.startsWith('#EXT-X-KEY:') &&
              attributes['METHOD'] == 'NONE') {
            continue;
          }
          final uri = attributes['URI'];
          if (uri == null ||
              !await File(p.join(directory.path, uri)).exists()) {
            return false;
          }
        }
        continue;
      }
      final file = File(p.join(directory.path, line));
      if (!await file.exists() || await file.length() == 0) return false;
    }
    return true;
  }

  Future<bool> _isMp4(File file) async {
    if (!await file.exists() || await file.length() < 12) return false;
    final handle = await file.open();
    try {
      final bytes = await handle.read(12);
      return bytes.length == 12 &&
          ascii.decode(bytes.sublist(4, 8), allowInvalid: true) == 'ftyp';
    } finally {
      await handle.close();
    }
  }

  Future<bool> _isFmp4Init(File file) async {
    if (!await file.exists() || await file.length() < 8) return false;
    final handle = await file.open();
    try {
      final bytes = await handle.read(8);
      final type = ascii.decode(bytes.sublist(4, 8), allowInvalid: true);
      return type == 'ftyp' || type == 'styp';
    } finally {
      await handle.close();
    }
  }

  Future<bool> _isAesKey(File file) async =>
      await file.exists() &&
      await file.length() == 16 &&
      !_looksLikeHtml(await file.readAsBytes());

  Future<bool> _isEncryptedHlsResource(File file) async {
    if (!await file.exists()) return false;
    final length = await file.length();
    if (length < 16 || length % 16 != 0) return false;
    final handle = await file.open();
    try {
      final bytes = await handle.read(length < 512 ? length : 512);
      return bytes.length == (length < 512 ? length : 512) &&
          !_looksLikeHtml(bytes);
    } finally {
      await handle.close();
    }
  }

  Future<bool> _isHlsSegment(File file, bool encrypted) async {
    if (!await file.exists() || await file.length() == 0) return false;
    final handle = await file.open();
    try {
      final length = await file.length();
      final bytes = await handle.read(length < 384 ? length : 384);
      if (_looksLikeHtml(bytes)) return false;
      if (encrypted) return bytes.length >= 16;
      if (length % 188 == 0 &&
          bytes.length >= 188 &&
          bytes.first == 0x47 &&
          (bytes.length < 376 || bytes[188] == 0x47)) {
        return true;
      }
      if (bytes.length >= 8) {
        final type = ascii.decode(bytes.sublist(4, 8), allowInvalid: true);
        if (const {
          'ftyp',
          'styp',
          'moof',
          'mdat',
          'sidx',
          'free',
        }.contains(type)) {
          return true;
        }
      }
      return bytes.length >= 3 &&
          (ascii.decode(bytes.take(3).toList(), allowInvalid: true) == 'ID3' ||
              (bytes[0] == 0xff && (bytes[1] & 0xf0) == 0xf0));
    } finally {
      await handle.close();
    }
  }

  bool _looksLikeHtml(List<int> bytes) {
    final prefix = ascii.decode(bytes.take(512).toList(), allowInvalid: true);
    final lower = prefix.trimLeft().toLowerCase();
    return lower.startsWith('<!doctype html') ||
        lower.startsWith('<html') ||
        lower.startsWith('<head') ||
        lower.startsWith('<body') ||
        lower.startsWith('<script') ||
        lower.startsWith('{"error"') ||
        lower.startsWith('{"message"') ||
        lower.contains('<html') ||
        lower.contains('<head') ||
        lower.contains('cf-challenge') ||
        lower.contains('just a moment');
  }

  void _reportProgress(
    _VideoDownloadOperation operation,
    double value, {
    required double persistWhenChangedBy,
  }) {
    if (!_canContinue(operation)) return;
    final task = forVideo(operation.id);
    if (task == null) return;
    final progress = value.clamp(0, 0.999).toDouble();
    if (progress - task.progress < 0.005) return;
    _replaceTask(task.copyWith(progress: progress));
    _notify();
    if (progress - operation.lastPersistedProgress >= persistWhenChangedBy) {
      operation.lastPersistedProgress = progress;
      unawaited(_persist().catchError((_) {}));
    }
  }

  void _ensureCurrent(_VideoDownloadOperation operation) {
    if (!_canContinue(operation)) {
      throw const HttpException('Video download cancelled');
    }
  }

  bool _canContinue(_VideoDownloadOperation operation) =>
      !_disposed &&
      !_deleting.contains(operation.id) &&
      identical(_active, operation) &&
      !operation.cancellation.isCancelled &&
      forVideo(operation.id)?.status == VideoDownloadStatus.downloading;

  void _replaceTask(VideoDownloadTask value) {
    final index = _tasks.indexWhere((task) => task.id == value.id);
    if (index >= 0) _tasks[index] = value;
  }

  bool _isQueued(VideoDownloadTask task) =>
      task.status == VideoDownloadStatus.queued;

  bool _isEligibleQueued(VideoDownloadTask task) =>
      _isQueued(task) && !_deleting.contains(task.id);

  bool _hasEligibleQueuedTask() => _tasks.any(_isEligibleQueued);

  VideoStream? _selectStream(VideoDetails details, String quality) {
    for (final stream in details.streams) {
      if (stream.label.trim().toLowerCase() == quality.trim().toLowerCase()) {
        return stream;
      }
    }
    return null;
  }

  bool _isHlsStream(VideoStream stream) {
    final uri = Uri.tryParse(stream.url);
    return stream.isHls || (uri?.path.toLowerCase().endsWith('.m3u8') ?? false);
  }

  Map<String, String> _headersFor(
    VideoItem video,
    Uri target,
    Map<String, String> headers,
  ) {
    final source = Uri.tryParse(video.pageUrl);
    if (source != null && _sameOrigin(source, target)) {
      return Map<String, String>.of(headers);
    }
    return {
      for (final entry in headers.entries)
        if (const {
          'accept',
          'accept-language',
          'user-agent',
          'referer',
          'origin',
        }.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
  }

  Map<String, String> _headersForUri(
    Uri initial,
    Uri target,
    Map<String, String> headers,
  ) => _sameOrigin(initial, target)
      ? Map<String, String>.of(headers)
      : {
          for (final entry in headers.entries)
            if (const {
              'accept',
              'accept-language',
              'user-agent',
              'referer',
              'origin',
            }.contains(entry.key.toLowerCase()))
              entry.key: entry.value,
        };

  bool _sameOrigin(Uri a, Uri b) =>
      a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;

  Uri _resolveHttpUri(Uri base, String value) =>
      _requireHttpUri(base.resolve(value));

  static Uri _requireHttpUri(Uri uri) {
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw const _VideoDownloadException(
        'The video source returned an unsupported media address.',
      );
    }
    return uri;
  }

  Future<Directory> _root() => _rootFuture ??= () async {
    final root =
        _providedRoot ??
        Directory(
          p.join(
            (await getApplicationSupportDirectory()).path,
            'video_downloads',
          ),
        );
    await root.create(recursive: true);
    _resolvedRoot = root;
    return root;
  }();

  Directory _taskDirectory(String id) =>
      Directory(p.join(_resolvedRoot!.path, _component(id)));

  String _localPath(VideoDownloadTask task) => p.join(
    _taskDirectory(task.id).path,
    task.isHls ? 'index.m3u8' : 'video.mp4',
  );

  static String _component(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  Future<void> _persist() async {
    if (_preferences == null) return;
    final value = jsonEncode(_tasks.map((task) => task.toJson()).toList());
    final pending = _writeTail.then((_) async {
      await _preferences!.setString(_tasksKey, value);
    });
    _writeTail = pending.catchError((_) {});
    await pending;
  }

  String _safeFailure(Object error) => error is _VideoDownloadException
      ? error.message
      : 'The video download failed. Check the source and retry.';

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _active?.cancellation.cancel();
    super.dispose();
  }

  Map<String, String> _parseAttributes(String source) {
    final result = <String, String>{};
    var start = 0;
    var quoted = false;
    final parts = <String>[];
    for (var index = 0; index < source.length; index++) {
      if (source[index] == '"') quoted = !quoted;
      if (source[index] == ',' && !quoted) {
        parts.add(source.substring(start, index));
        start = index + 1;
      }
    }
    parts.add(source.substring(start));
    for (final part in parts) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      var value = part.substring(separator + 1).trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      result[part.substring(0, separator).trim().toUpperCase()] = value;
    }
    return result;
  }

  String _replaceUriAttribute(String line, String localPath) {
    final pattern = RegExp(r'URI=(?:"[^"]*"|[^,]*)');
    return line.replaceFirst(pattern, 'URI="$localPath"');
  }

  int _hlsResourceCount(List<String> lines) => lines.where((rawLine) {
    final line = rawLine.trim();
    return line.isNotEmpty &&
        (!line.startsWith('#') ||
            line.startsWith('#EXT-X-KEY:') && line.contains('URI=') ||
            line.startsWith('#EXT-X-MAP:'));
  }).length;

  String _segmentExtension(Uri uri) {
    final extension = p.extension(uri.path).toLowerCase();
    return const {'.ts', '.m4s', '.mp4', '.aac'}.contains(extension)
        ? extension
        : '.ts';
  }
}

enum _HlsResourceKind { segment, key, map }

class _VideoDownloadOperation {
  _VideoDownloadOperation(this.id);

  final String id;
  final RemoteAssetCancellation cancellation = RemoteAssetCancellation();
  final Completer<void> done = Completer<void>();
  double lastPersistedProgress = 0;
}

class _VideoDownloadException implements Exception {
  const _VideoDownloadException(this.message);

  final String message;
}

class _FetchedText {
  const _FetchedText(this.baseUri, this.text);

  final Uri baseUri;
  final String text;
}

class _ResolvedPlaylist {
  const _ResolvedPlaylist(this.baseUri, this.lines);

  final Uri baseUri;
  final List<String> lines;
}

class _HlsVariant {
  const _HlsVariant({
    required this.uri,
    required this.bandwidth,
    this.audioGroup,
  });

  final Uri uri;
  final int bandwidth;
  final String? audioGroup;
}

class _VideoAssetTransport implements RemoteAssetTransport {
  _VideoAssetTransport({HttpClient? client})
    : _client = client ?? sharedMediaHttpClient;

  final HttpClient _client;

  @override
  Future<RemoteAssetResponse> open(RemoteAssetTransportRequest input) async {
    var uri = input.uri;
    var headers = Map<String, String>.of(input.headers);
    for (var redirects = 0; redirects <= 5; redirects++) {
      final requestFuture = _client.getUrl(uri);
      late final HttpClientRequest request;
      try {
        request = await Future.any<HttpClientRequest>([
          requestFuture,
          input.cancellation.whenCancelled.then<HttpClientRequest>(
            (_) => throw const HttpException('Video download cancelled'),
          ),
        ]);
      } catch (_) {
        if (input.cancellation.isCancelled) {
          unawaited(_abortWhenReady(requestFuture));
        }
        rethrow;
      }

      request.followRedirects = false;
      applyMediaRequestHeaders(
        request,
        uri,
        headers,
        forceIdentityEncoding: headers.keys.any(
          (name) => name.toLowerCase() == HttpHeaders.rangeHeader,
        ),
      );
      var waitingForResponse = true;
      unawaited(
        input.cancellation.whenCancelled.then((_) {
          if (waitingForResponse) {
            request.abort(const HttpException('Video download cancelled'));
          }
        }),
      );
      if (input.cancellation.isCancelled) {
        request.abort(const HttpException('Video download cancelled'));
      }
      final response = await request.close();
      waitingForResponse = false;
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (response.isRedirect && location != null) {
        await response.drain<void>();
        final next = VideoDownloads._requireHttpUri(uri.resolve(location));
        if (!_sameOrigin(uri, next)) {
          headers.removeWhere((name, _) => _isSensitiveHeader(name));
        }
        uri = next;
        continue;
      }
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name.toLowerCase()] = values.join(',');
      });
      return RemoteAssetResponse(
        statusCode: response.statusCode,
        contentLength: response.contentLength < 0
            ? null
            : response.contentLength,
        headers: responseHeaders,
        stream: cancellableHttpResponseStream(
          request: request,
          response: response,
          whenCancelled: input.cancellation.whenCancelled,
          isCancelled: () => input.cancellation.isCancelled,
          cancellationMessage: 'Video download cancelled',
        ),
        finalUri: uri,
      );
    }
    throw const HttpException('Too many redirects for video download');
  }

  Future<void> _abortWhenReady(Future<HttpClientRequest> requestFuture) async {
    try {
      final request = await requestFuture;
      request.abort(const HttpException('Video download cancelled'));
    } catch (_) {
      // The pending connection already failed.
    }
  }

  bool _sameOrigin(Uri a, Uri b) =>
      a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;

  bool _isSensitiveHeader(String name) {
    final value = name.toLowerCase();
    return value.contains('cookie') ||
        value.contains('authorization') ||
        value.contains('auth-token') ||
        value.contains('csrf') ||
        value.contains('xsrf');
  }
}
