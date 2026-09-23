import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/floating_lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/floating_lyric_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_latest_request_test.dart'
    show ControlledPlayer, MemorySessionStore, until;

const _tracks = [
  AudioTrack(
    id: 'a',
    title: 'A',
    url: 'https://example.invalid/a.wav',
    workId: 1,
  ),
  AudioTrack(
    id: 'b',
    title: 'B',
    url: 'https://example.invalid/b.wav',
    workId: 1,
  ),
];
const _files = [
  {'type': 'text', 'title': 'test.lrc'},
];
const _native = MethodChannel('com.kikoeru.flutter/floating_lyric');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Player player;
  late AudioPlayerService audio;
  late ProviderContainer container;
  late _Lyrics lyrics;
  late FloatingLyricEnabledNotifier floating;
  late Directory cacheRoot;
  final texts = <String>[];
  late Future<List<dynamic>> Function(AudioTrack) restoreFiles;

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));
  Future<void> nativeClose() async {
    final done = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _native.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('onClose'),
          ),
          (_) => done.complete(),
        );
    await done.future;
    await settle();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'server_host': 'https://example.invalid',
      'current_user': '{"name":"tester"}',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    cacheRoot = await Directory.systemTemp.createTemp('kiko-floating-lyrics-');
    texts.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => cacheRoot.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('mixin.one/desktop_multi_window'),
      (call) async {
        if (call.method == 'createWindow') return 'lyric-test';
        if (call.method == 'getAllWindows') return <dynamic>[];
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('mixin.one/desktop_multi_window/channels'),
      (call) async {
        final args = call.arguments as Map;
        if (args['method'] == 'updateText') {
          texts.add((args['arguments'] as Map)['text'] as String);
        }
        return true;
      },
    );
    messenger.setMockMethodCallHandler(_native, (call) async {
      if (call.method == 'updateText') {
        texts.add((call.arguments as Map)['text'] as String);
      }
      return true;
    });
    player = _Player();
    audio = AudioPlayerService.forTesting(
      player,
      sessionStore: MemorySessionStore(),
    );
    audio.updatePreloadThreshold(null);
    restoreFiles = (_) async => _files;
    container = ProviderContainer(
      overrides: [
        audioPlayerServiceProvider.overrideWithValue(audio),
        lyricControllerProvider.overrideWith((ref) => _Lyrics(ref)),
        playbackLyricFileTreeLoaderProvider.overrideWith(
          (ref) =>
              (track) => restoreFiles(track),
        ),
      ],
    );
    lyrics = container.read(lyricControllerProvider.notifier) as _Lyrics;
    container
        .read(fileListControllerProvider.notifier)
        .updateFiles(_files, workId: 1);
    await audio.updateQueue(_tracks, autoplay: true);
    floating = container.read(floatingLyricEnabledProvider.notifier);
    await settle();
  });

  tearDown(() async {
    container.dispose();
    await FloatingLyricService.instance.hide();
    await audio.dispose();
    await cacheRoot.delete(recursive: true);
  });

  test('floating window alone loads current and later tracks once', () async {
    await floating.toggle();
    await until(() => lyrics.loads.length == 1);
    expect(lyrics.loads, ['a']);
    await audio.skipToNext();
    await until(() => lyrics.loads.length == 2);
    await settle();
    expect(lyrics.loads, ['a', 'b']);
    expect(texts, contains('♪ 加载字幕中 ♪'));
    expect(texts.last, 'b');
    await audio.clearQueue();
    await settle();
    expect(container.read(lyricControllerProvider).lyrics, isEmpty);
  });

  test(
    'page and floating subscriptions share loads and page survives close',
    () async {
      final page = container.listen<void>(lyricAutoLoaderProvider, (_, __) {});
      addTearDown(page.close);
      await until(() => lyrics.loads.length == 1);
      await floating.toggle();
      await audio.skipToNext();
      await until(() => lyrics.loads.length == 2);
      expect(lyrics.loads, ['a', 'b']);
      await floating.toggle();
      await audio.skipToPrevious();
      await until(() => lyrics.loads.length == 3);
      expect(lyrics.loads, ['a', 'b', 'a']);
    },
  );

  test(
    'disable, reenable and native close release the loader subscription',
    () async {
      await floating.toggle();
      await until(() => lyrics.loads.length == 1);
      await floating.toggle();
      await audio.skipToNext();
      await settle();
      expect(lyrics.loads, ['a']);
      await floating.toggle();
      await until(() => lyrics.loads.length == 2);
      expect(lyrics.loads, ['a', 'b']);
      await nativeClose();
      expect(container.read(floatingLyricEnabledProvider), isFalse);
      await audio.skipToPrevious();
      await settle();
      expect(lyrics.loads, ['a', 'b']);
      await floating.toggle();
      await until(() => lyrics.loads.length == 3);
      await audio.skipToNext();
      await until(() => lyrics.loads.length == 4);
      expect(lyrics.loads, ['a', 'b', 'a', 'b']);
    },
  );

  test(
    'restoration ignores obsolete tracks and loads the latest file tree',
    () async {
      container.read(fileListControllerProvider.notifier).clear();
      final pending = Completer<List<dynamic>>();
      final restores = <String>[];
      restoreFiles = (track) {
        restores.add(track.id);
        return track.id == 'a' ? pending.future : Future.value(_files);
      };
      await floating.toggle();
      await until(() => restores.contains('a'));
      await audio.skipToNext();
      await until(() => lyrics.loads.isNotEmpty);
      pending.complete(_files);
      await settle();
      expect(lyrics.loads, ['b']);
      expect(container.read(fileListControllerProvider).workId, 1);
    },
  );

  test(
    'lyric results, playback changes and timer update window text',
    () async {
      await floating.toggle();
      await until(() => lyrics.loads.isNotEmpty);
      lyrics.publish('translated');
      await settle();
      expect(texts.last, 'translated');
      await audio.pause();
      player.states.add(player.playerState);
      await settle();
      expect(texts.last, '♪ - ♪');
      await audio.play();
      player.states.add(player.playerState);
      await settle();
      expect(texts.last, 'translated');
      player.position = const Duration(seconds: 20);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(texts.last, '♪ - ♪');
      await floating.toggle();
      final count = texts.length;
      lyrics.publish('closed');
      await settle();
      expect(texts, hasLength(count));
    },
  );

  test(
    'disposing the notifier releases its loader without disposing the container',
    () async {
      await floating.toggle();
      await until(() => lyrics.loads.length == 1);
      container.invalidate(floatingLyricEnabledProvider);
      await settle();
      await audio.skipToNext();
      await settle();
      expect(lyrics.loads, ['a']);
    },
  );
}

class _Player extends ControlledPlayer {
  final states = StreamController<PlayerState>.broadcast();
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Future<void> dispose() async {
    await states.close();
    await super.dispose();
  }
}

class _Lyrics extends LyricController {
  _Lyrics(super.ref);
  final loads = <String>[];
  @override
  Future<void> loadLyricForTrack(AudioTrack track, List<dynamic> files) async {
    loads.add(track.id);
    state = LyricState(isLoading: true);
    await Future<void>.delayed(Duration.zero);
    if (mounted) publish(track.id);
  }

  void publish(String text) {
    state = LyricState(
      lyrics: [
        LyricLine(
          startTime: Duration.zero,
          endTime: const Duration(seconds: 10),
          text: text,
        ),
      ],
    );
  }
}
