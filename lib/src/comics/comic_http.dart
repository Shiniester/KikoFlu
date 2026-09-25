import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import '../services/proxy_config.dart';
import '../services/storage_service.dart';
import '../services/log_service.dart';
import 'comic_models.dart';

/// One client per source; audio credentials are never consulted.
class ComicHttp {
  ComicHttp(this.source, {Dio? client})
    : dio =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 20),
            ),
          ) {
    if (client == null) {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () =>
            HttpClient()..findProxy = ProxyConfig.findProxyFor,
      );
    }
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.extra.putIfAbsent(
            'comicSessionGeneration',
            () => _sessionGeneration,
          );
          if (options.extra['comicSessionGeneration'] != _sessionGeneration) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.cancel,
                error: 'Comic account changed',
              ),
            );
            return;
          }
          options.headers.putIfAbsent('User-Agent', () => 'Mozilla/5.0');
          if (!acceptsSession(options.uri)) {
            options.headers.remove('Cookie');
            handler.next(options);
            return;
          }
          final cookie = StorageService.getString('comic_${source}_cookie');
          if (cookie != null && cookie.isNotEmpty) {
            options.headers.putIfAbsent('Cookie', () => cookie);
          }
          if (source == 'ehentai') {
            options.headers['Cookie'] =
                '${options.headers['Cookie'] ?? ''}; nw=1';
          }
          handler.next(options);
        },
        onResponse: (response, handler) async {
          if (response.requestOptions.extra['comicSessionGeneration'] !=
              _sessionGeneration) {
            handler.reject(
              DioException(
                requestOptions: response.requestOptions,
                type: DioExceptionType.cancel,
                error: 'Comic account changed',
              ),
            );
            return;
          }
          final values = response.headers['set-cookie'];
          if (values != null &&
              response.requestOptions.extra['comicSessionGeneration'] ==
                  _sessionGeneration &&
              acceptsSession(response.realUri)) {
            final cookies = <String, String>{};
            for (final part
                in (StorageService.getString('comic_${source}_cookie') ?? '')
                    .split(';')) {
              final i = part.indexOf('=');
              if (i > 0) {
                cookies[part.substring(0, i).trim()] = part
                    .substring(i + 1)
                    .trim();
              }
            }
            for (final value in values) {
              final cookie = Cookie.fromSetCookieValue(value);
              if (cookie.maxAge == 0) {
                cookies.remove(cookie.name);
              } else {
                cookies[cookie.name] = cookie.value;
              }
            }
            await saveSession(
              authenticated: false,
              cookie: cookies.entries
                  .map((e) => '${e.key}=${e.value}')
                  .join('; '),
            );
          }
          handler.next(response);
        },
      ),
    );
  }
  int _sessionGeneration = 0;
  Future<void> _pendingSessionWrite = Future.value();
  Future<void> _writeSession(
    int generation,
    Future<void> Function() write,
  ) async {
    final previous = _pendingSessionWrite;
    final completed = Completer<void>();
    _pendingSessionWrite = completed.future;
    await previous;
    try {
      if (generation == _sessionGeneration) await write();
    } finally {
      completed.complete();
    }
  }

  int get sessionGeneration => _sessionGeneration;
  final String source;
  final Dio dio;
  String? cookieValue(String name) {
    for (final pair
        in (StorageService.getString('comic_${source}_cookie') ?? '').split(
          ';',
        )) {
      final parts = pair.trim().split('=');
      if (parts.length > 1 && parts.first == name) {
        return parts.skip(1).join('=');
      }
    }
    return null;
  }

  String? get token => StorageService.getString('comic_${source}_token');
  bool acceptsSession(Uri uri) {
    final configured = StorageService.getString('comic_${source}_endpoint');
    final host = configured == null ? null : Uri.tryParse(configured)?.host;
    final hosts = switch (source) {
      'picacg' => ['picaapi.picacomic.com'],
      'ehentai' => ['e-hentai.org', 'exhentai.org'],
      'nhentai' => ['nhentai.net'],
      'jmcomic' => [host ?? 'www.cdntwice.org'],
      'htmanga' => [host ?? 'www.wnacg.com'],
      _ => <String>[],
    };
    return hosts.contains(uri.host);
  }

  bool get hasSession =>
      StorageService.getBool('comic_${source}_authenticated') ?? false;
  Future<void> saveSession({
    String? token,
    String? cookie,
    bool authenticated = true,
  }) async {
    await _writeSession(_sessionGeneration, () async {
      if (authenticated) {
        await StorageService.setBool('comic_${source}_authenticated', true);
      }
      if (token != null) {
        await StorageService.setString('comic_${source}_token', token);
      }
      if (cookie != null) {
        await StorageService.setString('comic_${source}_cookie', cookie);
      }
    });
  }

  Future<void> clearSession() async {
    final generation = ++_sessionGeneration;
    await _writeSession(generation, () async {
      await StorageService.remove('comic_${source}_token');
      await StorageService.remove('comic_${source}_cookie');
      await StorageService.remove('comic_${source}_authenticated');
    });
  }

  Future<Response<dynamic>> request(
    String url, {
    String method = 'GET',
    dynamic data,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    ResponseType? type,
    CancelToken? cancelToken,
  }) async {
    try {
      return await dio.request(
        url,
        data: data,
        queryParameters: query,
        cancelToken: cancelToken,
        options: Options(
          method: method,
          headers: headers,
          responseType: type,
          extra: {'comicSessionGeneration': _sessionGeneration},
        ),
      );
    } on DioException catch (e) {
      LogService.instance.warning(
        '$source ${Uri.parse(url).host}: ${e.type.name} (${e.response?.statusCode ?? 0})',
        tag: 'Comics',
      );
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        throw const ComicSourceException(
          'Sign in to this source in comic settings.',
          loginRequired: true,
        );
      }
      rethrow;
    }
  }

  Future<dynamic> json(
    String url, {
    String method = 'GET',
    dynamic data,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    final response = await request(
      url,
      method: method,
      data: data,
      query: query,
      headers: headers,
    );
    return response.data is String ? jsonDecode(response.data) : response.data;
  }

  Future<String> text(
    String url, {
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async =>
      (await request(
            url,
            query: query,
            headers: headers,
            type: ResponseType.plain,
          )).data
          as String;
  Future<Uint8List> bytes(
    String url, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async => Uint8List.fromList(
    List<int>.from(
      (await request(
        url,
        headers: headers,
        type: ResponseType.bytes,
        cancelToken: cancelToken,
      )).data,
    ),
  );
  void dispose() => dio.close(force: true);
}
