import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ApiServer {
  _ApiServer(this.server, this.requests);

  final HttpServer server;
  final List<Uri> requests;
}

Future<_ApiServer> _startServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <Uri>[];
  server.listen((request) async {
    requests.add(request.uri);
    await request.drain<void>();
    request.response
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..write(
        jsonEncode({
          'works': <dynamic>[],
          'pagination': {
            'currentPage': int.tryParse(
              request.uri.queryParameters['page'] ?? '',
            ),
            'pageSize': int.tryParse(
              request.uri.queryParameters['pageSize'] ?? '',
            ),
            'totalCount': 0,
          },
        }),
      );
    await request.response.close();
  });
  return _ApiServer(server, requests);
}

Future<Directory> _initializeCacheDirectory() async {
  SharedPreferences.setMockInitialValues({});
  await StorageService.initCritical(
    preferences: await SharedPreferences.getInstance(),
  );
  final directory = await Directory.systemTemp.createTemp('api-age-filter-');
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathProvider, (_) async => directory.path);
  return directory;
}

void _allowLocalHttpRequests() {
  final previousOverrides = HttpOverrides.current;
  HttpOverrides.global = null;
  addTearDown(() => HttpOverrides.global = previousOverrides);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('official age searches forward sort and a stable seed', () async {
    _allowLocalHttpRequests();
    final cacheDirectory = await _initializeCacheDirectory();
    final server = await _startServer();
    final api = KikoeruApiService()
      ..init(
        '',
        'http://127.0.0.1:${server.server.port}/api.asmr-test',
        accountScope: 'anonymous',
      );

    addTearDown(() async {
      api.dispose();
      await server.server.close(force: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      await cacheDirectory.delete(recursive: true);
    });

    await api.searchWorks(
      keyword: r'$age:general$',
      page: 4,
      pageSize: 40,
      source: AudioSource.asmrOne,
      order: 'release',
      sort: 'asc',
      subtitle: 1,
      seed: 31,
    );
    await api.searchWorks(
      keyword: r'$age:r15$',
      page: 2,
      pageSize: 20,
      source: AudioSource.asmrOne,
    );

    expect(server.requests, hasLength(2));
    expect(
      server.requests.first.toString(),
      contains('/api/search/${Uri.encodeComponent(r'$age:general$')}'),
    );
    expect(server.requests.first.queryParameters, {
      'page': '4',
      'pageSize': '40',
      'order': 'release',
      'sort': 'asc',
      'subtitle': '1',
      'seed': '31',
      'includeTranslationWorks': 'true',
    });
    expect(
      server.requests.last.toString(),
      contains('/api/search/${Uri.encodeComponent(r'$age:r15$')}'),
    );
    expect(server.requests.last.queryParameters['page'], '2');
    expect(server.requests.last.queryParameters['seed'], '21');
  });

  test('custom age-only searches use nsfw without a literal keyword', () async {
    _allowLocalHttpRequests();
    final cacheDirectory = await _initializeCacheDirectory();
    final server = await _startServer();
    final api = KikoeruApiService()
      ..init(
        '',
        'http://127.0.0.1:${server.server.port}',
        accountScope: 'anonymous',
      );

    addTearDown(() async {
      api.dispose();
      await server.server.close(force: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      await cacheDirectory.delete(recursive: true);
    });

    await api.searchWorks(
      keyword: r'$age:general$',
      page: 1,
      pageSize: 12,
      source: AudioSource.asmrOne,
    );

    expect(server.requests, hasLength(1));
    expect(server.requests.single.path, '/api/search');
    expect(server.requests.single.queryParameters['nsfw'], '1');
    expect(server.requests.single.queryParameters['keyword'], '[]');
    expect(
      server.requests.single.queryParameters['keyword'],
      isNot(contains(r'$age:general$')),
    );
  });
}
