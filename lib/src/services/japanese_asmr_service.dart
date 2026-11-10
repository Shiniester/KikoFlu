import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html;

import '../models/japanese_asmr_browse.dart';
import '../models/search_query.dart';
import '../models/search_type.dart';
import '../models/sort_options.dart';
import '../models/work.dart';

class JapaneseAsmrService {
  static final instance = JapaneseAsmrService();
  static final _apiBase = Uri.parse('https://earaasmr.com/api/jp-asmr/');

  final Dio _dio;
  final Map<int, String> _sourceIdsByPostId = {};
  final Map<int, String> _titlesByPostId = {};

  JapaneseAsmrService({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 20);
    _dio.options.receiveTimeout = const Duration(seconds: 25);
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          request.headers.removeWhere(
            (key, _) =>
                const ['authorization', 'cookie'].contains(key.toLowerCase()),
          );
          handler.next(request);
        },
      ),
    );
  }

  void registerWork(Work work) {
    if (!work.isJapaneseAsmr) return;
    final title = work.title.trim();
    if (title.isNotEmpty) _titlesByPostId[work.id.abs()] = title;
    final sourceId = _sourceId(work.sourceId);
    if (sourceId != null) _sourceIdsByPostId[work.id.abs()] = sourceId;
  }

  bool hasRegisteredWork(int postId) =>
      postId > 0 &&
      (_sourceIdsByPostId.containsKey(postId) ||
          _titlesByPostId.containsKey(postId));

  Future<Map<String, dynamic>> getWorks({
    required int page,
    required int pageSize,
    AgeRating ageRating = AgeRating.all,
    JapaneseAsmrSortOption? sort,
    SortDirection direction = SortDirection.desc,
    JapaneseAsmrPeriod period = JapaneseAsmrPeriod.week,
    int? archiveYear,
    int? archiveMonth,
    CancelToken? cancelToken,
  }) async {
    if ((ageRating != AgeRating.all && ageRating != AgeRating.general) ||
        (sort != null && sort != JapaneseAsmrSortOption.date) ||
        direction != SortDirection.desc ||
        period != JapaneseAsmrPeriod.week ||
        archiveYear != null ||
        archiveMonth != null) {
      throw UnsupportedError('Eara supports release-sorted JP-ASMR works only');
    }
    return _loadPage(
      query: '',
      page: page,
      pageSize: pageSize,
      allAges: ageRating == AgeRating.general,
      cancelToken: cancelToken,
    );
  }

  Future<Map<String, dynamic>> searchWorks({
    required String keyword,
    required int page,
    required int pageSize,
    List<SearchCondition> conditions = const [],
    CancelToken? cancelToken,
  }) async {
    if (conditions.any(
      (condition) =>
          condition.isExclude ||
          (condition.type != SearchType.keyword &&
              condition.type != SearchType.rjNumber),
    )) {
      throw UnsupportedError('Eara supports keyword search only');
    }
    return _loadPage(
      query: keyword.trim(),
      page: page,
      pageSize: pageSize,
      cancelToken: cancelToken,
    );
  }

  Future<List<Map<String, dynamic>>> getSearchCatalog(
    SearchType type, {
    CancelToken? cancelToken,
  }) async {
    throw UnsupportedError('Eara does not provide a search catalog');
  }

  Future<Map<String, dynamic>> _loadPage({
    required String query,
    required int page,
    required int pageSize,
    bool allAges = false,
    CancelToken? cancelToken,
  }) async {
    if (page < 1 || pageSize < 1) throw ArgumentError('Invalid page');
    final offset = (page - 1) * pageSize;
    final response = await _getJson(
      _apiBase.resolve('search'),
      queryParameters: {
        'q': query,
        'limit': pageSize,
        'offset': offset,
        'sort': 'release',
        if (allAges) 'allAges': true,
      },
      cancelToken: cancelToken,
    );
    final rawItems = response['items'];
    if (rawItems is! List) {
      throw const FormatException('Eara search response has no items list');
    }
    final works = <Map<String, dynamic>>[];
    for (final rawItem in rawItems) {
      if (rawItem is! Map) {
        throw const FormatException('Eara search item is not an object');
      }
      works.add(_workJson(Map<String, dynamic>.from(rawItem)));
    }
    final total = _requiredInt(response['total'], 'total');
    return {
      'works': works,
      'pagination': {
        'currentPage': page,
        'pageSize': pageSize,
        'totalCount': total,
        'hasMore': offset + works.length < total,
      },
    };
  }

  Future<Map<String, dynamic>> getWork(
    int postId, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    final item = await _lookupWork(postId, cancelToken: cancelToken);
    return _workJson(item, expectedPostId: postId);
  }

  Future<List<dynamic>> getWorkTracks(
    int postId, {
    bool forceRefresh = false,
  }) async {
    final item = await _lookupWork(postId);
    final sourceId = _sourceId(item['rj'])!;
    final response = await _getJson(
      _apiBase.resolve('tracks'),
      queryParameters: {'rj': sourceId},
    );
    if (_sourceId(response['rj']) != sourceId ||
        _requiredInt(response['workId'], 'workId') != postId) {
      throw const FormatException(
        'Eara track response does not match the work',
      );
    }
    final rawTree = response['trackTree'];
    if (rawTree is! List) {
      throw const FormatException('Eara track response has no track tree');
    }
    final audioIndex = [0];
    return _mapTrackTree(rawTree, postId: postId, audioIndex: audioIndex);
  }

  List<dynamic> _mapTrackTree(
    List<dynamic> rawNodes, {
    required int postId,
    required List<int> audioIndex,
  }) {
    final nodes = <Map<String, dynamic>>[];
    for (final rawNode in rawNodes) {
      if (rawNode is! Map) {
        throw const FormatException('Eara track node is not an object');
      }
      final node = Map<String, dynamic>.from(rawNode);
      final type = node['type'];
      final title = _requiredString(node['title'], 'title');
      if (type == 'folder') {
        final children = node['children'];
        if (children is! List) {
          throw const FormatException('Eara folder has no children list');
        }
        nodes.add({
          'type': 'folder',
          'title': title,
          'children': _mapTrackTree(
            children,
            postId: postId,
            audioIndex: audioIndex,
          ),
        });
      } else if (type == 'audio') {
        audioIndex[0]++;
        nodes.add(_mapAudioTrack(node, title, postId, audioIndex[0]));
      } else {
        throw FormatException('Unsupported Eara track type: $type');
      }
    }
    return nodes;
  }

  Map<String, dynamic> _mapAudioTrack(
    Map<String, dynamic> node,
    String title,
    int postId,
    int audioIndex,
  ) {
    final directDownloadUrl = _optionalHttpsUrl(node['mediaDownloadUrl']);
    final streamUrl = _optionalHttpsUrl(node['streamUrl']) ?? directDownloadUrl;
    if (streamUrl == null) {
      throw const FormatException('Eara audio has no valid media URL');
    }
    final streamUri = Uri.parse(streamUrl);
    final fragmentParameters = Uri.splitQueryString(streamUri.fragment);
    final chapter = fragmentParameters['eara-chapter'];
    final cleanStreamUrl = streamUri.removeFragment().toString();
    final isHls = streamUri.path.toLowerCase().endsWith('.m3u8');
    int? startTimeMs;
    int? endTimeMs;
    if (chapter != null) {
      final range = _chapterRange(chapter);
      if (isHls) {
        startTimeMs = range.$1;
        endTimeMs = range.$2;
      } else if (range.$1 != 0 || range.$2 != null) {
        throw const FormatException(
          'Non-HLS Eara chapter ranges are unsupported',
        );
      }
    }

    final hash = startTimeMs != null
        ? 'jp-$postId-chapter-$startTimeMs'
        : 'jp-$postId${audioIndex == 1 ? '-main' : '-file-$audioIndex'}';
    return {
      'type': 'audio',
      'title': startTimeMs == null
          ? title
          : _chapterFileName(title, audioIndex),
      'hash': hash,
      'mediaStreamUrl': cleanStreamUrl,
      if (startTimeMs != null) ...{
        'mediaDownloadUrl': cleanStreamUrl,
        'startTimeMs': startTimeMs,
        'endTimeMs': endTimeMs,
      } else if (directDownloadUrl != null)
        'mediaDownloadUrl': directDownloadUrl
      else if (!isHls)
        'mediaDownloadUrl': cleanStreamUrl,
      if (node['duration'] is num) 'duration': node['duration'],
      if (node['size'] is num) 'size': (node['size'] as num).toInt(),
    };
  }

  static String _chapterFileName(String title, int chapterNumber) {
    final stem = title.replaceFirst(
      RegExp(r'\.(?:aac|mp3|m4a|wav|flac|ogg|opus)$', caseSensitive: false),
      '',
    );
    return '${chapterNumber}_$stem.aac';
  }

  static (int, int?) _chapterRange(String value) {
    final times = value.split(',');
    if (times.length != 2) {
      throw const FormatException('Invalid Eara chapter interval');
    }
    final startTimeMs = int.tryParse(times[0]);
    final rawEnd = times[1];
    final endTimeMs = rawEnd.isEmpty ? null : int.tryParse(rawEnd);
    if (startTimeMs == null ||
        startTimeMs < 0 ||
        (rawEnd.isNotEmpty && endTimeMs == null) ||
        (endTimeMs != null && endTimeMs <= startTimeMs)) {
      throw const FormatException('Invalid Eara chapter interval');
    }
    return (startTimeMs, endTimeMs);
  }

  Future<List<dynamic>> getRelatedWorks(int postId) async {
    throw UnsupportedError('Eara does not provide related works');
  }

  Future<String> resolveDownloadUrl(
    String url, {
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    var uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasAuthority ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('Invalid JP-ASMR download URL');
    }
    if (_isJapaneseAsmrHost(uri) && uri.path == '/dlc.php') {
      uri = await _resolveLegacyFullWorkDownload(uri, cancelToken);
    }
    if (_isJapaneseAsmrHost(uri)) {
      throw const FormatException('Source-site download URLs are unsupported');
    }
    if (uri.host == 'buzzheavier.com' ||
        uri.host.endsWith('.buzzheavier.com')) {
      final page = await _getText(uri, cancelToken: cancelToken);
      final path = html
          .parse(page.data)
          .querySelector('a.download-btn[hx-get]')
          ?.attributes['hx-get'];
      if (path == null) {
        throw const FormatException('Audio host download is unavailable');
      }
      final target = page.realUri.resolve(path);
      final response = await _getText(
        target,
        headers: {'HX-Request': 'true', 'Referer': page.realUri.toString()},
        cancelToken: cancelToken,
      );
      final redirect = response.headers.value('HX-Redirect');
      final targetUrl = redirect == null ? null : target.resolve(redirect);
      if (targetUrl == null || !_isDownloadUri(targetUrl)) {
        throw const FormatException('Audio host did not provide a download');
      }
      return targetUrl.toString();
    }
    if (uri.path.toLowerCase().endsWith('.m3u8')) {
      throw const FormatException('JP-ASMR playlist is not a download URL');
    }
    return uri.toString();
  }

  Future<Uri> _resolveLegacyFullWorkDownload(
    Uri sourceUri,
    CancelToken? cancelToken,
  ) async {
    final sourceId = _sourceId(sourceUri.queryParameters['f']);
    if (sourceId == null) {
      throw const FormatException('Legacy full-work URL has no source ID');
    }
    final response = await _getJson(
      _apiBase.resolve('tracks'),
      queryParameters: {'rj': sourceId},
      cancelToken: cancelToken,
    );
    if (_sourceId(response['rj']) != sourceId ||
        response['trackTree'] is! List) {
      throw const FormatException(
        'Eara track response does not match the work',
      );
    }
    final fullAudio = _audioNodes(response['trackTree'] as List).where((node) {
      final title = _optionalString(node['title']);
      final downloadUrl = _optionalHttpsUrl(node['mediaDownloadUrl']);
      if (title == null || downloadUrl == null) return false;
      final streamUrl = _optionalHttpsUrl(node['streamUrl']);
      if (streamUrl != null) {
        final chapter = Uri.splitQueryString(
          Uri.parse(streamUrl).fragment,
        )['eara-chapter'];
        if (chapter != null) {
          try {
            final range = _chapterRange(chapter);
            if (range.$1 != 0 || range.$2 != null) return false;
          } on FormatException {
            return false;
          }
        }
      }
      final fileName = title.replaceAll('\\', '/').split('/').last;
      final extension = fileName.lastIndexOf('.');
      final stem = extension < 0 ? fileName : fileName.substring(0, extension);
      return stem.toUpperCase() == sourceId;
    }).toList();
    if (fullAudio.length != 1) {
      throw const FormatException(
        'Eara does not provide one confirmed full-work download',
      );
    }
    return Uri.parse(
      _httpsUrl(fullAudio.single['mediaDownloadUrl'], 'mediaDownloadUrl'),
    );
  }

  List<Map<String, dynamic>> _audioNodes(List<dynamic> tree) {
    final audio = <Map<String, dynamic>>[];
    for (final rawNode in tree) {
      if (rawNode is! Map) continue;
      final node = Map<String, dynamic>.from(rawNode);
      if (node['type'] == 'audio') {
        audio.add(node);
      } else if (node['type'] == 'folder' && node['children'] is List) {
        audio.addAll(_audioNodes(node['children'] as List));
      }
    }
    return audio;
  }

  Future<Response<String>> _getText(
    Uri uri, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) => _dio.get<String>(
    uri.toString(),
    options: Options(responseType: ResponseType.plain, headers: headers),
    cancelToken: cancelToken,
  );

  static bool _isDownloadUri(Uri uri) =>
      const ['http', 'https'].contains(uri.scheme) &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.path.toLowerCase().endsWith('.m3u8');

  static bool _isJapaneseAsmrHost(Uri uri) =>
      uri.host == 'japaneseasmr.com' || uri.host.endsWith('.japaneseasmr.com');

  Future<Map<String, dynamic>> _getJson(
    Uri uri, {
    required Map<String, dynamic> queryParameters,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get<dynamic>(
      uri.toString(),
      queryParameters: queryParameters,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.json,
        headers: const {'Accept': 'application/json'},
      ),
    );
    final statusCode = response.statusCode;
    if (statusCode == null || statusCode < 200 || statusCode >= 300) {
      if (statusCode == null) {
        throw const FormatException('Eara returned no HTTP status');
      }
      throw DioException.badResponse(
        statusCode: statusCode,
        requestOptions: response.requestOptions,
        response: response,
      );
    }
    final data = response.data;
    final decoded = data is String ? jsonDecode(data) : data;
    if (decoded is! Map) {
      throw const FormatException('Eara response is not a JSON object');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<Map<String, dynamic>> _lookupWork(
    int postId, {
    CancelToken? cancelToken,
  }) async {
    final sourceId = _sourceIdsByPostId[postId];
    final title = _titlesByPostId[postId];
    if (postId <= 0 || (sourceId == null && title == null)) {
      throw FormatException(
        'JP-ASMR page $postId has no registered source ID or title',
      );
    }
    final query = sourceId ?? title!;
    final response = await _getJson(
      _apiBase.resolve('search'),
      queryParameters: {
        'q': query,
        'limit': 20,
        'offset': 0,
        'sort': 'release',
      },
      cancelToken: cancelToken,
    );
    final rawItems = response['items'];
    if (rawItems is! List) {
      throw const FormatException('Eara search response has no items list');
    }
    for (final rawItem in rawItems) {
      if (rawItem is! Map) continue;
      final item = Map<String, dynamic>.from(rawItem);
      final itemPostId = _requiredInt(item['workId'], 'workId');
      final itemSourceId = _sourceId(item['rj']);
      if (sourceId != null && itemSourceId != sourceId) continue;
      if (sourceId == null && itemPostId != postId) continue;
      if (itemPostId != postId || itemSourceId == null) continue;
      _sourceIdsByPostId[postId] = itemSourceId;
      return item;
    }
    throw FormatException('Eara work not found for page $postId');
  }

  Map<String, dynamic> _workJson(
    Map<String, dynamic> item, {
    int? expectedPostId,
  }) {
    final postId = _requiredInt(item['workId'], 'workId');
    if (postId <= 0 || (expectedPostId != null && expectedPostId != postId)) {
      throw const FormatException('Eara work ID does not match the page ID');
    }
    final sourceId = _sourceId(item['rj']);
    if (sourceId == null) {
      throw const FormatException('Eara work has no valid source ID');
    }
    final title = _requiredString(item['title'], 'title');
    _sourceIdsByPostId[postId] = sourceId;

    final work = <String, dynamic>{
      'id': -postId,
      'title': title,
      'source_id': sourceId,
    };
    final circle = _optionalString(item['circle']);
    if (circle != null) work['name'] = circle;
    final pageUrl = _optionalHttpsUrl(item['pageUrl']);
    if (pageUrl != null) work['source_url'] = pageUrl;
    final coverUrl = _optionalHttpsUrl(item['mainCoverUrl']);
    if (coverUrl != null) work['cover_url'] = coverUrl;
    final release =
        _optionalString(item['releaseDate']) ??
        _optionalString(item['publishedAt']);
    if (release != null) work['release'] = release;
    if (item['allAges'] == true) work['age'] = 'general';
    work['vas'] = _namedValues(item['cvs'], tags: false);
    final tags = item['tags'];
    work['tags'] = _namedValues(
      tags is List && tags.isNotEmpty ? tags : item['tagDetails'],
      tags: true,
    );
    return work;
  }

  static List<Map<String, dynamic>> _namedValues(
    dynamic rawValues, {
    required bool tags,
  }) {
    if (rawValues is! List) return const [];
    final values = <Map<String, dynamic>>[];
    for (final raw in rawValues) {
      final name = raw is String
          ? raw.trim()
          : raw is Map
          ? _optionalString(
              raw['name'] ??
                  raw['label'] ??
                  raw['title'] ??
                  raw['originalName'],
            )
          : null;
      if (name == null || name.isEmpty) continue;
      values.add({'id': tags ? -(values.length + 1) : name, 'name': name});
    }
    return values;
  }

  static String _httpsUrl(dynamic value, String field) {
    final url = _optionalHttpsUrl(value);
    if (url == null) throw FormatException('Eara has no valid $field');
    return url;
  }

  static String? _optionalHttpsUrl(dynamic value) {
    if (value is! String || value.trim().isEmpty) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.toString();
  }

  static String _requiredString(dynamic value, String field) {
    final string = _optionalString(value);
    if (string == null || string.isEmpty) {
      throw FormatException('Eara has no valid $field');
    }
    return string;
  }

  static String? _optionalString(dynamic value) {
    if (value is! String) return null;
    final string = value.trim();
    return string.isEmpty ? null : string;
  }

  static int _requiredInt(dynamic value, String field) {
    if (value is num && value.isFinite && value == value.toInt()) {
      return value.toInt();
    }
    throw FormatException('Eara has no valid $field');
  }

  static String? _sourceId(dynamic value) {
    if (value is! String) return null;
    final normalized = value.trim().toUpperCase();
    return RegExp(r'^(?:RJ|BJ|VJ|UND|UN)\d+$').hasMatch(normalized)
        ? normalized
        : null;
  }
}
