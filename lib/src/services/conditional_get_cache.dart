import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'cache_file_transaction.dart';
import 'remote_asset_cache.dart';

typedef ConditionalCacheDirectoryProvider = Future<Directory> Function();
typedef ConditionalCacheScopeProvider = String Function();

/// Adds persistent HTTP validation and in-flight de-duplication to JSON GETs.
class ConditionalGetCache extends Interceptor {
  ConditionalGetCache({
    required ConditionalCacheDirectoryProvider directoryProvider,
    required ConditionalCacheScopeProvider scopeProvider,
  }) : // Keep the public named arguments free of private-field prefixes.
       // ignore: prefer_initializing_formals
       _directoryProvider = directoryProvider,
       // ignore: prefer_initializing_formals
       _scopeProvider = scopeProvider;

  static const _keyExtra = 'kikoflu.conditionalCache.key';
  static const _entryExtra = 'kikoflu.conditionalCache.entry';
  static const _leaderExtra = 'kikoflu.conditionalCache.leader';
  static const _inFlightKeyExtra = 'kikoflu.conditionalCache.inFlightKey';
  static const _consumerExtra = 'kikoflu.conditionalCache.consumer';
  static const _sharedRequestExtra = 'kikoflu.conditionalCache.sharedRequest';
  static const _callerCancelExtra =
      'kikoflu.conditionalCache.callerCancelToken';
  static const _inFlightOnlyExtra = 'kikoflu.conditionalCache.inFlightOnly';
  static const _generationExtra = 'kikoflu.conditionalCache.generation';
  static const forceRefreshExtra = 'kikoflu.conditionalCache.forceRefresh';
  static int _processGeneration = 0;
  static final Set<Future<void>> _processWrites = {};

  final ConditionalCacheDirectoryProvider _directoryProvider;
  final ConditionalCacheScopeProvider _scopeProvider;
  final Map<String, _ConditionalEntry> _memory = {};
  final Map<String, _SharedConditionalRequest> _inFlight = {};
  final Set<Future<void>> _pendingWrites = {};
  int _generation = 0;
  int _observedProcessGeneration = _processGeneration;

  /// Invalidates fresh in-memory responses in every API service instance.
  /// Disk entries are removed by the cache service under the shared budget.
  static Future<void> invalidateProcessMemory() async {
    _processGeneration++;
    await Future.wait(
      List<Future<void>>.of(
        _processWrites,
      ).map((write) => write.then<void>((_) {}, onError: (_) {})),
    );
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    _synchronizeProcessGeneration();
    final method = options.method.toUpperCase();
    final persistentGet = method == 'GET';
    final sharedReadPost =
        method == 'POST' &&
        options.uri.path.toLowerCase().startsWith('/api/recommender/');
    if (!persistentGet && !sharedReadPost) {
      handler.next(options);
      return;
    }

    final key = _requestKey(options);
    // Register the caller before the first asynchronous disk lookup. Otherwise
    // a fast cancellation can abort the leader while an identical second
    // caller is still waiting to discover the same persisted variant.
    final inFlightKey = _inFlightRequestKey(key, options.headers);
    var pending = _inFlight[inFlightKey];
    if (pending?.transportToken.isCancelled ?? false) {
      _inFlight.remove(inFlightKey);
      pending = null;
    }
    final callerCancelToken = options.cancelToken;
    if (pending != null) {
      final consumer = pending.attach(callerCancelToken);
      try {
        final waitResult = await consumer.wait();
        if (waitResult.cancellation != null) {
          handler.reject(
            _callerCancellation(waitResult.cancellation!, options),
          );
        } else {
          final outcome = waitResult.outcome!;
          if (outcome.error != null) {
            handler.reject(
              DioException(
                requestOptions: options,
                error: outcome.error,
                stackTrace: outcome.stackTrace,
              ),
            );
          } else {
            handler.resolve(outcome.toResponse(options));
          }
        }
      } finally {
        consumer.release();
      }
      return;
    }

    final sharedRequest = _SharedConditionalRequest();
    final consumer = sharedRequest.attach(callerCancelToken);
    _inFlight[inFlightKey] = sharedRequest;
    options.extra[_keyExtra] = key;
    options.extra[_inFlightKeyExtra] = inFlightKey;
    options.extra[_leaderExtra] = true;
    options.extra[_sharedRequestExtra] = sharedRequest;
    options.extra[_consumerExtra] = consumer;
    options.extra[_callerCancelExtra] = callerCancelToken;
    options.extra[_generationExtra] = (_generation, _processGeneration);
    options.cancelToken = sharedRequest.transportToken;

    _ConditionalEntry? entry;
    try {
      if (persistentGet) {
        entry = await _readEntry(key, options.headers);
        final forceRefresh = options.extra[forceRefreshExtra] == true;
        if (!forceRefresh &&
            entry != null &&
            entry.validTill.isAfter(DateTime.now())) {
          final cachedResponse = _responseFromEntry(entry, options);
          _completeLeader(
            options,
            _ConditionalOutcome.response(cachedResponse),
          );
          final callerCancellation = _cancelledCaller(options);
          if (callerCancellation != null) {
            handler.reject(_callerCancellation(callerCancellation, options));
          } else {
            handler.resolve(cachedResponse);
          }
          return;
        }

        if (entry?.etag != null) {
          options.headers['If-None-Match'] = entry!.etag;
        }
        if (entry?.lastModified != null) {
          options.headers['If-Modified-Since'] = entry!.lastModified;
        }
      } else {
        options.extra[_inFlightOnlyExtra] = true;
      }
      options.extra[_entryExtra] = entry;
    } catch (error, stackTrace) {
      _completeLeader(options, _ConditionalOutcome.error(error, stackTrace));
      handler.reject(
        DioException(
          requestOptions: options,
          error: error,
          stackTrace: stackTrace,
        ),
      );
      return;
    }

    final originalValidateStatus = options.validateStatus;
    options.validateStatus = (status) {
      if (status == HttpStatus.notModified) return true;
      return originalValidateStatus(status);
    };
    // The transport is cancelled only after every visible caller releases.
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final options = response.requestOptions;
    final key = options.extra[_keyExtra] as String?;
    if (key == null) {
      handler.next(response);
      return;
    }

    if (options.extra[_inFlightOnlyExtra] == true) {
      _completeLeader(options, _ConditionalOutcome.response(response));
      final callerCancellation = _cancelledCaller(options);
      if (callerCancellation != null) {
        handler.reject(_callerCancellation(callerCancellation, options));
        return;
      }
      handler.next(response);
      return;
    }

    final mayPersist =
        options.extra[_generationExtra] == (_generation, _processGeneration);

    Response<dynamic> effectiveResponse = response;
    try {
      if (response.statusCode == HttpStatus.notModified) {
        final cached =
            options.extra[_entryExtra] as _ConditionalEntry? ??
            await _readEntry(key, options.headers);
        if (cached == null) {
          throw const HttpException('Received 304 without a cached body');
        }
        final cacheControl = response.headers.value('cache-control') ?? '';
        final vary = response.headers.value('vary');
        final refreshed = cached.copyWith(
          validTill: _validTill(response.headers),
          etag: response.headers.value('etag') ?? cached.etag,
          lastModified:
              response.headers.value('last-modified') ?? cached.lastModified,
          varyHeaders: vary == null
              ? cached.varyHeaders
              : _varyValues(vary, options.headers),
        );
        if (_hasDirective(cacheControl, 'no-store') ||
            vary == '*' ||
            _variesOnSensitiveHeader(vary)) {
          await _removeMatchingEntry(key, options.headers);
        } else if (mayPersist && _isGenerationCurrent(options)) {
          try {
            await _writeEntry(key, refreshed);
          } on FileSystemException {
            // A cache write failure must not hide a valid cached response.
          }
        }
        effectiveResponse = _responseFromEntry(refreshed, options);
      } else if (response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 300) {
        final cacheControl = response.headers.value('cache-control') ?? '';
        final vary = response.headers.value('vary');
        try {
          if (_hasDirective(cacheControl, 'no-store') ||
              vary == '*' ||
              _variesOnSensitiveHeader(vary)) {
            await _removeMatchingEntry(key, options.headers);
          } else if (mayPersist && _isGenerationCurrent(options)) {
            final entry = _ConditionalEntry(
              uri: RemoteAssetKey.canonicalUri(options.uri),
              dataJson: jsonEncode(response.data),
              statusCode: response.statusCode!,
              statusMessage: response.statusMessage,
              headers: _safeResponseHeaders(response.headers.map),
              validTill: _validTill(response.headers),
              etag: response.headers.value('etag'),
              lastModified: response.headers.value('last-modified'),
              varyHeaders: _varyValues(vary, options.headers),
            );
            await _writeEntry(key, entry);
          }
        } on FileSystemException {
          // The network response remains authoritative when persistence fails.
        } on JsonUnsupportedObjectError {
          // Only JSON-compatible responses are persisted; callers still get
          // the original successful response.
        }
      }
      _completeLeader(options, _ConditionalOutcome.response(effectiveResponse));
      final callerCancellation = _cancelledCaller(options);
      if (callerCancellation != null) {
        handler.reject(_callerCancellation(callerCancellation, options));
        return;
      }
      handler.next(effectiveResponse);
    } catch (error, stackTrace) {
      _completeLeader(options, _ConditionalOutcome.error(error, stackTrace));
      final callerCancellation = _cancelledCaller(options);
      if (callerCancellation != null) {
        handler.reject(_callerCancellation(callerCancellation, options));
        return;
      }
      handler.reject(
        DioException(
          requestOptions: options,
          response: response,
          error: error,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _completeLeader(
      err.requestOptions,
      _ConditionalOutcome.error(err, err.stackTrace),
    );
    handler.next(err);
  }

  Future<void> invalidateAll() async {
    _generation++;
    _memory.clear();
    await Future.wait(
      List<Future<void>>.of(
        _pendingWrites,
      ).map((write) => write.then<void>((_) {}, onError: (_) {})),
    );
    _memory.clear();
    final directory = await _directoryProvider();
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is File &&
          !FileRemoteAssetCache.isCachePathActive(entity.path)) {
        try {
          await entity.delete();
        } on FileSystemException {
          // A response may be completing while the mutation invalidates cache.
        }
      }
    }
  }

  Future<void> invalidatePathFamilies(Iterable<String> pathFamilies) async {
    final families = pathFamilies
        .map(_normalizePathFamily)
        .where((path) => path.isNotEmpty)
        .toSet();
    if (families.isEmpty) return;

    _generation++;
    await Future.wait(
      List<Future<void>>.of(
        _pendingWrites,
      ).map((write) => write.then<void>((_) {}, onError: (_) {})),
    );
    _memory.removeWhere((_, entry) => _matchesPathFamily(entry, families));

    final directory = await _directoryProvider();
    if (!await directory.exists()) return;
    await _recoverAllEntryBackups(directory);
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      if (FileRemoteAssetCache.isCachePathActive(entity.path)) continue;

      FileRemoteAssetCache.markCachePathActive(entity.path);
      try {
        final entry = _ConditionalEntry.fromJson(
          jsonDecode(await entity.readAsString()) as Map<String, dynamic>,
        );
        if (!_matchesPathFamily(entry, families)) continue;
        final name = p.basename(entity.path);
        _memory.remove(name.substring(0, name.length - '.json'.length));
        await entity.delete();
        final backup = cacheFileBackup(entity);
        if (await backup.exists()) await backup.delete();
      } on FileSystemException {
        // A fresh response may be replacing this entry concurrently.
      } on FormatException {
        // Normal reads will discard malformed entries if they are requested.
      } finally {
        FileRemoteAssetCache.unmarkCachePathActive(entity.path);
      }
    }
  }

  String _normalizePathFamily(String value) {
    var path = value.trim();
    if (path.isEmpty) return '';
    if (!path.startsWith('/')) path = '/$path';
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  bool _matchesPathFamily(_ConditionalEntry entry, Set<String> families) {
    final uri = Uri.tryParse(entry.uri);
    if (uri == null) return false;
    return families.any(
      (family) => uri.path == family || uri.path.startsWith('$family/'),
    );
  }

  Future<void> _recoverAllEntryBackups(Directory directory) async {
    await for (final entity in directory.list()) {
      if (entity is! File ||
          !p.basename(entity.path).endsWith(cacheFileBackupSuffix)) {
        continue;
      }
      final destinationPath = entity.path.substring(
        0,
        entity.path.length - cacheFileBackupSuffix.length,
      );
      if (destinationPath.endsWith('.json')) {
        await recoverCacheFileReplacement(File(destinationPath));
      }
    }
  }

  void _synchronizeProcessGeneration() {
    if (_observedProcessGeneration == _processGeneration) return;
    _observedProcessGeneration = _processGeneration;
    _generation++;
    _memory.clear();
  }

  bool _isGenerationCurrent(RequestOptions options) {
    return options.extra[_generationExtra] == (_generation, _processGeneration);
  }

  String _requestKey(RequestOptions options) {
    final method = options.method.toUpperCase();
    final body = method == 'GET'
        ? ''
        : '\u0000${jsonEncode(_canonicalData(options.data))}';
    final canonical =
        '${_scopeProvider()}\u0000$method\u0000'
        '${RemoteAssetKey.canonicalUri(options.uri)}$body';
    return canonical;
  }

  String _inFlightRequestKey(
    String persistentKey,
    Map<String, dynamic> requestHeaders, {
    Iterable<String>? varyNames,
  }) {
    final normalized = <String, String>{
      for (final entry in requestHeaders.entries)
        entry.key.toLowerCase(): entry.value.toString(),
    };
    final names = (varyNames ?? normalized.keys).toSet().toList()..sort();
    final variants = <String, String>{
      for (final name in names) name: normalized[name] ?? '',
    };
    return '$persistentKey\u0000${jsonEncode(variants)}';
  }

  dynamic _canonicalData(dynamic value) {
    if (value is Map) {
      final converted = <String, dynamic>{
        for (final entry in value.entries) entry.key.toString(): entry.value,
      };
      final keys = converted.keys.toList()..sort();
      return {for (final key in keys) key: _canonicalData(converted[key])};
    }
    if (value is Iterable) {
      return value.map(_canonicalData).toList(growable: false);
    }
    return value;
  }

  Response<dynamic> _responseFromEntry(
    _ConditionalEntry entry,
    RequestOptions options,
  ) {
    return Response<dynamic>(
      requestOptions: options,
      data: jsonDecode(entry.dataJson),
      statusCode: entry.statusCode,
      statusMessage: entry.statusMessage,
      headers: Headers.fromMap(entry.headers),
    );
  }

  DateTime _validTill(Headers headers) {
    final now = DateTime.now();
    final cacheControl = headers.value('cache-control') ?? '';
    if (_hasDirective(cacheControl, 'no-cache') ||
        _hasDirective(cacheControl, 'must-revalidate')) {
      return now;
    }
    final match = RegExp(
      r'(^|,)\s*max-age=(\d+)',
      caseSensitive: false,
    ).firstMatch(cacheControl);
    if (match != null) {
      return now.add(Duration(seconds: int.parse(match.group(2)!)));
    }
    final expires = headers.value('expires');
    if (expires != null) {
      try {
        return HttpDate.parse(expires);
      } on FormatException {
        // Invalid server metadata is treated as immediately stale.
      }
    }
    return now;
  }

  bool _hasDirective(String cacheControl, String directive) {
    return cacheControl
        .split(',')
        .any((value) => value.trim().toLowerCase() == directive);
  }

  bool _variesOnSensitiveHeader(String? vary) {
    if (vary == null || vary.trim().isEmpty) return false;
    return vary
        .split(',')
        .map((value) => value.trim().toLowerCase())
        .any(_isSensitiveHeader);
  }

  Map<String, String> _varyValues(
    String? vary,
    Map<String, dynamic> requestHeaders,
  ) {
    if (vary == null || vary.trim().isEmpty) return const {};
    final normalized = <String, String>{
      for (final entry in requestHeaders.entries)
        entry.key.toLowerCase(): entry.value.toString(),
    };
    return {
      for (final name
          in vary.split(',').map((value) => value.trim().toLowerCase()))
        if (name.isNotEmpty) name: normalized[name] ?? '',
    };
  }

  Map<String, List<String>> _safeResponseHeaders(
    Map<String, List<String>> headers,
  ) {
    return {
      for (final entry in headers.entries)
        if (!_isSensitiveHeader(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
  }

  bool _isSensitiveHeader(String name) => const {
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
  }.contains(name);

  bool _varyMatches(
    _ConditionalEntry entry,
    Map<String, dynamic> requestHeaders,
  ) {
    if (entry.varyHeaders.isEmpty) return true;
    final normalized = <String, String>{
      for (final header in requestHeaders.entries)
        header.key.toLowerCase(): header.value.toString(),
    };
    return entry.varyHeaders.entries.every(
      (header) => (normalized[header.key] ?? '') == header.value,
    );
  }

  Future<_ConditionalEntry?> _readEntry(
    String baseKey,
    Map<String, dynamic> requestHeaders,
  ) async {
    final candidates = await _loadEntries(baseKey);
    candidates.sort(
      (first, second) => second.entry.varyHeaders.length.compareTo(
        first.entry.varyHeaders.length,
      ),
    );
    for (final candidate in candidates) {
      if (_varyMatches(candidate.entry, requestHeaders)) {
        return candidate.entry;
      }
    }
    return null;
  }

  Future<void> _writeEntry(String key, _ConditionalEntry entry) {
    late final Future<void> pending;
    pending = _writeEntryNow(key, entry).whenComplete(() {
      _pendingWrites.remove(pending);
      _processWrites.remove(pending);
    });
    _pendingWrites.add(pending);
    _processWrites.add(pending);
    return pending;
  }

  Future<void> _writeEntryNow(String baseKey, _ConditionalEntry entry) async {
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    final storageKey = _entryStorageKey(baseKey, entry.varyHeaders);
    final file = File(p.join(directory.path, '$storageKey.json'));
    final temporary = File('${file.path}.tmp');
    FileRemoteAssetCache.markCachePathActive(file.path);
    FileRemoteAssetCache.markCachePathActive(temporary.path);
    try {
      await temporary.writeAsString(jsonEncode(entry.toJson()), flush: true);
      await replaceCacheFile(temporary, file);
      _memory[storageKey] = entry;
      await _removeObsoleteVariants(baseKey, storageKey, entry);
    } finally {
      FileRemoteAssetCache.unmarkCachePathActive(temporary.path);
      FileRemoteAssetCache.unmarkCachePathActive(file.path);
    }
  }

  Future<void> _removeMatchingEntry(
    String baseKey,
    Map<String, dynamic> requestHeaders,
  ) async {
    final entries = await _loadEntries(baseKey);
    for (final stored in entries) {
      if (_varyMatches(stored.entry, requestHeaders)) {
        await _removeStoredEntry(stored);
      }
    }
  }

  Future<List<_StoredConditionalEntry>> _loadEntries(String baseKey) async {
    final directory = await _directoryProvider();
    if (!await directory.exists()) return const [];
    final baseStorageKey = _encodeStorageComponent(baseKey);
    await _recoverEntryBackups(directory, baseStorageKey);

    final entries = <_StoredConditionalEntry>[];
    final loadedKeys = <String>{};
    for (final memoryEntry in _memory.entries) {
      if (!_storageKeyBelongsTo(memoryEntry.key, baseStorageKey)) continue;
      loadedKeys.add(memoryEntry.key);
      entries.add(
        _StoredConditionalEntry(
          storageKey: memoryEntry.key,
          entry: memoryEntry.value,
          file: File(p.join(directory.path, '${memoryEntry.key}.json')),
        ),
      );
    }

    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final storageKey = _storageKeyForFile(entity, baseStorageKey);
      if (storageKey == null || loadedKeys.contains(storageKey)) continue;
      FileRemoteAssetCache.markCachePathActive(entity.path);
      try {
        final entry = _ConditionalEntry.fromJson(
          jsonDecode(await entity.readAsString()) as Map<String, dynamic>,
        );
        _memory[storageKey] = entry;
        loadedKeys.add(storageKey);
        entries.add(
          _StoredConditionalEntry(
            storageKey: storageKey,
            entry: entry,
            file: entity,
          ),
        );
      } catch (_) {
        await entity.delete();
      } finally {
        FileRemoteAssetCache.unmarkCachePathActive(entity.path);
      }
    }
    return entries;
  }

  Future<void> _recoverEntryBackups(
    Directory directory,
    String baseStorageKey,
  ) async {
    await for (final entity in directory.list()) {
      if (entity is! File ||
          !p.basename(entity.path).endsWith(cacheFileBackupSuffix)) {
        continue;
      }
      final destinationPath = entity.path.substring(
        0,
        entity.path.length - cacheFileBackupSuffix.length,
      );
      final destinationName = p.basename(destinationPath);
      if (destinationName == '$baseStorageKey.json' ||
          (destinationName.startsWith('$baseStorageKey.') &&
              destinationName.endsWith('.json'))) {
        await recoverCacheFileReplacement(File(destinationPath));
      }
    }
  }

  String? _storageKeyForFile(File file, String baseStorageKey) {
    final name = p.basename(file.path);
    if (!name.endsWith('.json')) return null;
    final storageKey = name.substring(0, name.length - '.json'.length);
    return _storageKeyBelongsTo(storageKey, baseStorageKey) ? storageKey : null;
  }

  bool _storageKeyBelongsTo(String storageKey, String baseStorageKey) {
    return storageKey == baseStorageKey ||
        storageKey.startsWith('$baseStorageKey.');
  }

  String _entryStorageKey(String baseKey, Map<String, String> varyHeaders) {
    final names = varyHeaders.keys.toList()..sort();
    final canonical = <String, String>{
      for (final name in names) name: varyHeaders[name]!,
    };
    final request = _encodeStorageComponent(baseKey);
    final variant = _encodeStorageComponent(jsonEncode(canonical));
    return '$request.$variant';
  }

  String _encodeStorageComponent(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  Future<void> _removeObsoleteVariants(
    String baseKey,
    String currentStorageKey,
    _ConditionalEntry current,
  ) async {
    final entries = await _loadEntries(baseKey);
    final currentNames = current.varyHeaders.keys.toSet();
    for (final stored in entries) {
      if (stored.storageKey == currentStorageKey) continue;
      final storedNames = stored.entry.varyHeaders.keys.toSet();
      final sameNames =
          storedNames.length == currentNames.length &&
          storedNames.containsAll(currentNames);
      final duplicate =
          sameNames &&
          _sameHeaderIdentities(stored.entry.varyHeaders, current.varyHeaders);
      if (!sameNames || duplicate) await _removeStoredEntry(stored);
    }
  }

  bool _sameHeaderIdentities(
    Map<String, String> first,
    Map<String, String> second,
  ) {
    if (first.length != second.length) return false;
    return first.entries.every((entry) => second[entry.key] == entry.value);
  }

  Future<void> _removeStoredEntry(_StoredConditionalEntry stored) async {
    _memory.remove(stored.storageKey);
    if (await stored.file.exists()) await stored.file.delete();
    final backup = cacheFileBackup(stored.file);
    if (await backup.exists()) await backup.delete();
  }

  void _completeLeader(RequestOptions options, _ConditionalOutcome outcome) {
    if (options.extra[_leaderExtra] != true) return;
    final key = options.extra[_inFlightKeyExtra] as String?;
    if (key == null) return;
    final request =
        options.extra[_sharedRequestExtra] as _SharedConditionalRequest?;
    if (request != null && identical(_inFlight[key], request)) {
      _inFlight.remove(key);
    }
    request?.complete(outcome);
    (options.extra[_consumerExtra] as _SharedConditionalConsumer?)?.release();
  }

  DioException? _cancelledCaller(RequestOptions options) {
    final token = options.extra[_callerCancelExtra] as CancelToken?;
    return token?.isCancelled == true ? token!.cancelError : null;
  }

  DioException _callerCancellation(
    DioException cancellation,
    RequestOptions options,
  ) {
    return DioException.requestCancelled(
      requestOptions: options,
      reason: cancellation.error,
      stackTrace: cancellation.stackTrace,
    );
  }
}

class _SharedConditionalRequest {
  final Completer<_ConditionalOutcome> _outcome =
      Completer<_ConditionalOutcome>();
  final CancelToken transportToken = CancelToken();
  int _consumerCount = 0;
  bool _completed = false;

  _SharedConditionalConsumer attach(CancelToken? callerToken) {
    _consumerCount++;
    final consumer = _SharedConditionalConsumer(this, callerToken);
    if (callerToken?.isCancelled == true) {
      consumer.release();
    } else if (callerToken != null) {
      unawaited(callerToken.whenCancel.then((_) => consumer.release()));
    }
    return consumer;
  }

  Future<_SharedWaitResult> wait(CancelToken? callerToken) {
    if (callerToken == null) {
      return _outcome.future.then(_SharedWaitResult.outcome);
    }
    return Future.any([
      _outcome.future.then(_SharedWaitResult.outcome),
      callerToken.whenCancel.then(_SharedWaitResult.cancelled),
    ]);
  }

  void release(_SharedConditionalConsumer consumer) {
    if (consumer._released) return;
    consumer._released = true;
    if (_consumerCount > 0) _consumerCount--;
    if (!_completed && _consumerCount == 0 && !transportToken.isCancelled) {
      transportToken.cancel('Every shared request consumer was released');
    }
  }

  void complete(_ConditionalOutcome outcome) {
    if (_completed) return;
    _completed = true;
    if (!_outcome.isCompleted) _outcome.complete(outcome);
  }
}

class _SharedConditionalConsumer {
  _SharedConditionalConsumer(this._request, this._callerToken);

  final _SharedConditionalRequest _request;
  final CancelToken? _callerToken;
  bool _released = false;

  Future<_SharedWaitResult> wait() => _request.wait(_callerToken);

  void release() => _request.release(this);
}

class _SharedWaitResult {
  const _SharedWaitResult._({this.outcome, this.cancellation});

  factory _SharedWaitResult.outcome(_ConditionalOutcome outcome) {
    return _SharedWaitResult._(outcome: outcome);
  }

  factory _SharedWaitResult.cancelled(DioException cancellation) {
    return _SharedWaitResult._(cancellation: cancellation);
  }

  final _ConditionalOutcome? outcome;
  final DioException? cancellation;
}

class _ConditionalOutcome {
  const _ConditionalOutcome._({
    this.data,
    this.statusCode,
    this.statusMessage,
    this.headers,
    this.error,
    this.stackTrace,
  });

  factory _ConditionalOutcome.response(Response<dynamic> response) {
    return _ConditionalOutcome._(
      data: response.data,
      statusCode: response.statusCode,
      statusMessage: response.statusMessage,
      headers: response.headers.map,
    );
  }

  factory _ConditionalOutcome.error(Object error, StackTrace stackTrace) {
    return _ConditionalOutcome._(error: error, stackTrace: stackTrace);
  }

  final dynamic data;
  final int? statusCode;
  final String? statusMessage;
  final Map<String, List<String>>? headers;
  final Object? error;
  final StackTrace? stackTrace;

  Response<dynamic> toResponse(RequestOptions options) {
    return Response<dynamic>(
      requestOptions: options,
      data: data,
      statusCode: statusCode,
      statusMessage: statusMessage,
      headers: Headers.fromMap(headers ?? const {}),
    );
  }
}

class _ConditionalEntry {
  const _ConditionalEntry({
    required this.uri,
    required this.dataJson,
    required this.statusCode,
    required this.headers,
    required this.validTill,
    required this.varyHeaders,
    this.statusMessage,
    this.etag,
    this.lastModified,
  });

  factory _ConditionalEntry.fromJson(Map<String, dynamic> json) {
    return _ConditionalEntry(
      uri: json['uri'] as String,
      dataJson: json['dataJson'] as String,
      statusCode: json['statusCode'] as int,
      statusMessage: json['statusMessage'] as String?,
      headers: (json['headers'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, List<String>.from(value as List)),
      ),
      validTill: DateTime.fromMillisecondsSinceEpoch(json['validTill'] as int),
      etag: json['etag'] as String?,
      lastModified: json['lastModified'] as String?,
      varyHeaders: Map<String, String>.from(
        json['varyHeaders'] as Map? ?? const {},
      ),
    );
  }

  final String uri;
  final String dataJson;
  final int statusCode;
  final String? statusMessage;
  final Map<String, List<String>> headers;
  final DateTime validTill;
  final String? etag;
  final String? lastModified;
  final Map<String, String> varyHeaders;

  _ConditionalEntry copyWith({
    DateTime? validTill,
    String? etag,
    String? lastModified,
    Map<String, String>? varyHeaders,
  }) {
    return _ConditionalEntry(
      uri: uri,
      dataJson: dataJson,
      statusCode: statusCode,
      statusMessage: statusMessage,
      headers: headers,
      validTill: validTill ?? this.validTill,
      etag: etag ?? this.etag,
      lastModified: lastModified ?? this.lastModified,
      varyHeaders: varyHeaders ?? this.varyHeaders,
    );
  }

  Map<String, Object?> toJson() => {
    'uri': uri,
    'dataJson': dataJson,
    'statusCode': statusCode,
    'statusMessage': statusMessage,
    'headers': headers,
    'validTill': validTill.millisecondsSinceEpoch,
    'etag': etag,
    'lastModified': lastModified,
    'varyHeaders': varyHeaders,
  };
}

class _StoredConditionalEntry {
  const _StoredConditionalEntry({
    required this.storageKey,
    required this.entry,
    required this.file,
  });

  final String storageKey;
  final _ConditionalEntry entry;
  final File file;
}
