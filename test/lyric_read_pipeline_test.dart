import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = AudioTrack(
  id: 'a',
  title: 'track.wav',
  url: 'track.wav',
  workId: 1,
);
const _file = {'title': 'track.lrc', 'type': 'text', 'hash': 'subtitle'};

class _Auth extends StateNotifier<AuthState> implements AuthNotifier {
  _Auth(String host) : super(AuthState(host: host, token: 'test-token'));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Priority extends SubtitleLibraryPriorityNotifier {
  _Priority() {
    state = SubtitleLibraryPriority.lowest;
  }
}

class _Network extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HttpServer server;
  late ProviderContainer container;
  late LyricController controller;
  late String host;
  final requests = <HttpRequest>[];
  var hold = false;
  var status = HttpStatus.ok;
  const content = '[00:01.00]shared subtitle';
  final previousOverrides = HttpOverrides.current;

  setUpAll(() {
    HttpOverrides.global = _Network();
  });
  tearDownAll(() {
    HttpOverrides.global = previousOverrides;
  });

  Future<void> createContainer({
    String? serverHost,
    AudioTrack? track = _track,
  }) async {
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith((ref) => _Auth(serverHost ?? host)),
        currentTrackProvider.overrideWith((ref) => Stream.value(track)),
        subtitleLibraryPriorityProvider.overrideWith((ref) => _Priority()),
      ],
    );
    await container.read(currentTrackProvider.future);
    controller = container.read(lyricControllerProvider.notifier);
  }

  Future<void> respond(HttpRequest request) async {
    request.response.statusCode = status;
    request.response.write(content);
    await request.response.close();
  }

  Future<void> waitForRequests(int count) async {
    for (var i = 0; i < 200 && requests.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(requests, hasLength(count));
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('kiko-lyric-read-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    requests.clear();
    hold = false;
    status = HttpStatus.ok;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host = 'http://127.0.0.1:${server.port}';
    server.listen((request) {
      requests.add(request);
      if (!hold) unawaited(respond(request));
    });
    await createContainer();
  });

  tearDown(() async {
    container.dispose();
    await server.close(force: true);
    await CacheService.remoteAssetCache.clearInactive();
    await directory.delete(recursive: true);
  });

  Future<LyricState> load(
    bool manual, {
    Map<String, dynamic> file = _file,
    int? workId = 1,
  }) async {
    if (manual) {
      await controller.loadLyricManually(file, workId: workId);
    } else {
      await controller.loadLyricForTrack(_track, [file]);
    }
    return container.read(lyricControllerProvider);
  }

  for (final manual in [false, true]) {
    final entry = manual ? 'manual' : 'automatic';
    test('$entry reads local files with matching source metadata', () async {
      final local = File('${directory.path}/track.lrc');
      await local.writeAsString(content);
      final state = await load(
        manual,
        file: {..._file, 'localPath': local.path},
      );
      expect(state.lyrics.single.text, 'shared subtitle');
      expect(state.source?.type, LyricSourceType.localFile);
      expect(state.source?.hash, 'subtitle');
      expect(state.source?.workId, 1);
      expect(state.lyricUrl, 'file://${local.path}');
      expect(requests, isEmpty);
    });

    test('$entry uses cached text without a network request', () async {
      await CacheService.cacheTextContent(
        workId: 1,
        hash: 'subtitle',
        content: content,
      );
      final state = await load(manual);
      expect(state.lyrics.single.text, 'shared subtitle');
      expect(state.source?.type, LyricSourceType.remote);
      expect(
        state.source?.url,
        '$host/api/media/stream/subtitle?token=test-token',
      );
      expect(requests, isEmpty);
    });

    test('$entry reads and parses remote subtitles', () async {
      final state = await load(manual);
      expect(state.lyrics.single.text, 'shared subtitle');
      expect(state.source?.title, 'track.lrc');
      expect(requests, hasLength(1));
      expect(requests.single.uri.queryParameters['token'], 'test-token');
    });

    test('$entry reports a missing local file without throwing', () async {
      final state = await load(
        manual,
        file: {..._file, 'localPath': '${directory.path}/missing.lrc'},
      );
      expect(state.error, '文件不存在');
    });

    test('$entry preserves remote read error semantics', () async {
      status = HttpStatus.internalServerError;
      if (manual) {
        await expectLater(load(manual), throwsA(isA<HttpException>()));
      } else {
        await load(manual);
      }
      expect(
        container.read(lyricControllerProvider).error,
        startsWith('加载字幕失败:'),
      );
    });
  }

  for (final serverHost in [
    'http://example.test',
    'https://localhost:88',
    'localhost:88',
    '127.0.0.1:88',
    '192.168.1.2:88',
    'example.test',
  ]) {
    test('both entries normalize $serverHost identically', () async {
      container.dispose();
      await createContainer(serverHost: serverHost);
      await CacheService.cacheTextContent(
        workId: 1,
        hash: 'subtitle',
        content: content,
      );
      final automatic = await load(false);
      final manual = await load(true);
      final expectedHost = serverHost.contains('://')
          ? serverHost
          : serverHost == 'example.test'
          ? 'https://$serverHost'
          : 'http://$serverHost';
      expect(
        automatic.lyricUrl,
        '$expectedHost/api/media/stream/subtitle?token=test-token',
      );
      expect(manual.lyricUrl, automatic.lyricUrl);
      expect(requests, isEmpty);
    });
  }

  test('manual work ID precedence controls the cache and source', () async {
    for (final id in [1, 2, 3]) {
      await CacheService.cacheTextContent(
        workId: id,
        hash: 'subtitle',
        content: '[00:01.00]$id',
      );
    }
    expect(
      (await load(
        true,
        file: {..._file, 'workId': 2},
        workId: 3,
      )).lyrics.single.text,
      '3',
    );
    expect(
      (await load(
        true,
        file: {..._file, 'workId': 2},
        workId: null,
      )).lyrics.single.text,
      '2',
    );
    final fallback = await load(true, workId: null);
    expect(fallback.lyrics.single.text, '1');
    expect(fallback.source?.workId, 1);
    expect(requests, isEmpty);
  });

  test('manual permits no work ID while automatic requires one', () async {
    container.dispose();
    await createContainer(track: null);
    const anonymous = AudioTrack(id: 'x', title: 'track.wav', url: 'x');
    await controller.loadLyricForTrack(anonymous, [_file]);
    expect(container.read(lyricControllerProvider).error, isNull);
    expect(requests, isEmpty);
    final manual = await load(true, workId: null);
    expect(manual.lyrics.single.text, 'shared subtitle');
    expect(manual.source?.workId, isNull);
  });

  test(
    'missing information is silent automatically and explicit manually',
    () async {
      final file = {'title': 'track.lrc', 'type': 'text'};
      expect((await load(false, file: file)).error, isNull);
      expect((await load(true, file: file)).error, '缺少必要信息');
    },
  );

  test(
    'same-resource automatic to manual handoff shares one request',
    () async {
      hold = true;
      final automatic = load(false);
      await waitForRequests(1);
      final manual = load(true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requests, hasLength(1));
      await respond(requests.single);
      await Future.wait([automatic, manual]);
      expect(
        container.read(lyricControllerProvider).lyrics.single.text,
        'shared subtitle',
      );
    },
  );

  test('a newer local selection replaces a pending remote request', () async {
    hold = true;
    final automatic = load(false);
    await waitForRequests(1);
    final local = File('${directory.path}/new.lrc');
    await local.writeAsString('[00:01.00]new local');
    await controller.loadLyricFromLocalFile(local.path);
    await automatic;
    expect(
      container.read(lyricControllerProvider).lyrics.single.text,
      'new local',
    );
    expect(
      container.read(lyricControllerProvider).source?.type,
      LyricSourceType.localFile,
    );
  });

  test(
    'switching remote resources cannot let the old request release the new one',
    () async {
      hold = true;
      final automatic = load(false);
      await waitForRequests(1);
      final manual = load(true, file: {..._file, 'hash': 'second-subtitle'});
      await waitForRequests(2);
      await automatic;
      expect(container.read(lyricControllerProvider).isLoading, isTrue);
      await respond(requests.last);
      await manual;
      expect(
        container.read(lyricControllerProvider).source?.hash,
        'second-subtitle',
      );
    },
  );

  test(
    'manual to automatic handoff also shares the pending resource',
    () async {
      hold = true;
      final manual = load(true);
      await waitForRequests(1);
      final automatic = load(false);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requests, hasLength(1));
      await respond(requests.single);
      await Future.wait([manual, automatic]);
      expect(container.read(lyricControllerProvider).source?.hash, 'subtitle');
    },
  );

  test(
    'empty manual selection restores visible lyrics and their offset',
    () async {
      final local = File('${directory.path}/old.lrc');
      await local.writeAsString(content);
      await controller.loadLyricFromLocalFile(local.path);
      controller.adjustTimelineOffset(const Duration(seconds: 2));
      final previous = container.read(lyricControllerProvider);
      final empty = File('${directory.path}/empty.lrc');
      await empty.writeAsString('');
      await expectLater(
        controller.selectLyricManually({'localPath': empty.path}),
        throwsFormatException,
      );
      expect(container.read(lyricControllerProvider), same(previous));
    },
  );

  test('disposing during a remote read releases the request', () async {
    hold = true;
    final automatic = controller.loadLyricForTrack(_track, [_file]);
    await waitForRequests(1);
    container.invalidate(lyricControllerProvider);
    await automatic;
  });
}
