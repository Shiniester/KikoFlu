import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/playback_diagnostic_event.dart';
import 'package:kikoeru_flutter/src/performance/performance_build_guard.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/log_service.dart';
import 'package:kikoeru_flutter/src/services/speculative_transfer_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_backend_native_fixture.dart';
import '../third_party/just_audio_media_kit/test/native_cache_lifecycle_cases.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final supported = Platform.isAndroid || Platform.isWindows;
  const library = String.fromEnvironment('KIKOFLU_AUDIO_LIBMPV');

  setUpAll(() {
    if (supported) {
      JustAudioMediaKit.ensureInitialized(
        android: true,
        windows: true,
        libmpv: library.isEmpty ? null : library,
      );
    }
  });

  if (supported) {
    registerNativeCacheLifecycleCases(
      gzip.decode(base64Decode(audioBackendWavGzipBase64)),
      _nativeContract,
    );
  }

  tearDownAll(() {
    debugPrint(
      'AUDIO_BACKEND_CONTRACT_RESULT ${jsonEncode(binding.reportData)}',
    );
  });

  testWidgets('native adapter seeks FLAC with an empty SEEKTABLE', (
    tester,
  ) async {
    await _nativeContract(() async {
      final directory = await Directory.systemTemp.createTemp(
        'kiko-backend-contract-',
      );
      final bytes = Uint8List.fromList(
        gzip.decode(base64Decode(audioBackendFlacGzipBase64)),
      );
      expect(_emptySeekTable(bytes), isTrue);
      final source = File('${directory.path}/empty-seektable.flac');
      await source.writeAsBytes(bytes);
      final player = await _configuredPlayer();
      final errors = <Object>[];
      final subscription = player.playbackEventStream.listen(
        (_) {},
        onError: errors.add,
      );
      try {
        final duration = await player
            .setFilePath(source.path)
            .timeout(const Duration(seconds: 10));
        expect(duration, const Duration(seconds: 24));
        unawaited(player.play());
        await _until(
          () =>
              player.playing &&
              player.position >= const Duration(milliseconds: 500),
        );
        final metrics = <Map<String, Object>>[];
        for (final percent in [25, 80, 10]) {
          final target = duration! * (percent / 100);
          await player.seek(target).timeout(const Duration(seconds: 10));
          await _until(
            () =>
                player.processingState == ProcessingState.ready &&
                player.playbackEvent.updatePosition >=
                    target + const Duration(milliseconds: 500),
          );
          expect(player.playing, isTrue);
          expect(
            player.position,
            lessThan(target + const Duration(seconds: 3)),
          );
          metrics.add({
            'percent': percent,
            'target_ms': target.inMilliseconds,
            'advanced_position_ms': player.position.inMilliseconds,
          });
        }
        expect(errors, isEmpty);
        binding.reportData = {
          'empty_seektable': metrics,
          'gate_status': 'incomplete',
        };
      } finally {
        await player.dispose();
        await subscription.cancel();
        await directory.delete(recursive: true);
      }
    });
  }, skip: !supported);

  for (final clipped in [false, true]) {
    testWidgets(
      'native adapter preserves authenticated ${clipped ? 'clipped ' : ''}HTTP routes and ranges',
      (tester) async {
        await _nativeContract(() async {
          final requests = <Map<String, Object>>[];
          final server = await _serveAuthenticatedAudio(requests);
          final savedBuffer = JustAudioMediaKit.bufferSize;
          JustAudioMediaKit.bufferSize = 8 * 1024;
          final player = await _configuredPlayer();
          final errors = <Object>[];
          final states = <String>[];
          final subscription = player.playbackEventStream.listen((event) {
            if (states.isEmpty || states.last != event.processingState.name) {
              states.add(event.processingState.name);
            }
          }, onError: errors.add);
          try {
            final uri = Uri.parse('http://127.0.0.1:${server.port}$_route');
            final child = AudioSource.uri(
              uri,
              headers: const {'Authorization': _authorization},
            );
            final source = clipped
                ? ClippingAudioSource(
                    child: child,
                    start: const Duration(seconds: 4),
                    end: const Duration(seconds: 20),
                  )
                : child;
            final duration = await player
                .setAudioSource(source)
                .timeout(const Duration(seconds: 10));
            expect(duration, Duration(seconds: clipped ? 16 : 24));
            if (clipped) {
              expect(player.bufferedPosition, lessThanOrEqualTo(duration!));
            }
            unawaited(player.play());
            await _until(
              () =>
                  player.playbackEvent.updatePosition >=
                  const Duration(milliseconds: 500),
            );
            for (final target in [
              Duration(seconds: clipped ? 12 : 19),
              const Duration(seconds: 2),
            ]) {
              await player.seek(target).timeout(const Duration(seconds: 10));
              await _until(
                () =>
                    player.processingState == ProcessingState.ready &&
                    player.playbackEvent.updatePosition >=
                        target + const Duration(milliseconds: 500),
              );
              if (clipped) {
                expect(player.bufferedPosition, lessThanOrEqualTo(duration!));
              }
            }
            if (clipped) {
              await player.seek(const Duration(seconds: 15));
              await _until(
                () => player.processingState == ProcessingState.completed,
              );
              await player.pause();
              expect(player.processingState, ProcessingState.completed);
              await player.seek(Duration.zero);
              unawaited(player.play());
              await _until(
                () =>
                    player.processingState == ProcessingState.ready &&
                    player.playbackEvent.updatePosition >=
                        const Duration(milliseconds: 500),
              );
              expect(
                await player.setAudioSource(child),
                const Duration(seconds: 24),
              );
              expect(player.processingState, ProcessingState.ready);
              unawaited(player.play());
              await _until(
                () =>
                    player.playbackEvent.updatePosition >=
                    const Duration(milliseconds: 500),
              );
              expect(player.processingState, ProcessingState.ready);
            }
            expect(errors, isEmpty);
            debugPrint('AUDIO_BACKEND_HTTP ${jsonEncode(requests)}');
            expect(requests, isNotEmpty);
            expect(
              requests.every(
                (r) =>
                    r['route'] == _route &&
                    r['authorization'] == _authorization,
              ),
              isTrue,
            );
            expect(
              requests.any(
                (r) =>
                    (r['range'] as String).isNotEmpty &&
                    !(r['range'] as String).startsWith('bytes=0-'),
              ),
              isTrue,
              reason:
                  'A real byte-range request must reach the authenticated origin after seeking',
            );
            binding.reportData = {
              ...?binding.reportData,
              clipped ? 'authenticated_clipping' : 'authenticated_http':
                  requests,
              'gate_status': 'incomplete',
            };
          } finally {
            debugPrint(
              'AUDIO_BACKEND_HTTP_FINAL ${jsonEncode({'clipped': clipped, 'states': states, 'position_ms': player.playbackEvent.updatePosition.inMilliseconds, 'playing': player.playing, 'requests': requests})}',
            );
            await player.dispose();
            await subscription.cancel();
            JustAudioMediaKit.bufferSize = savedBuffer;
            await server.close(force: true);
          }
        });
      },
      skip: !supported,
    );
  }

  testWidgets(
    'native audio loads with configured music session attributes',
    (tester) async {
      await _nativeContract(() async {
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());
        expect(
          session.androidAudioAttributes?.contentType,
          AndroidAudioContentType.music,
        );

        final directory = await Directory.systemTemp.createTemp(
          'kiko-audio-session-',
        );
        final source = File.fromUri(directory.uri.resolve('music.wav'));
        await source.writeAsBytes(
          gzip.decode(base64Decode(audioBackendWavGzipBase64)),
        );
        final player = AudioPlayer(androidApplyAudioAttributes: false);
        if (Platform.isWindows) {
          await _configureNativePlayer(player.platformId, (_) async {});
        }
        try {
          expect(
            await player
                .setFilePath(source.path)
                .timeout(const Duration(seconds: 10)),
            const Duration(seconds: 24),
          );
        } finally {
          await player.dispose();
          await directory.delete(recursive: true);
        }
      });
    },
    skip: !supported,
  );

  testWidgets(
    'Android duck end restores the app output level without clamping gain',
    (tester) async {
      await _nativeContract(() async {
        const channel = MethodChannel('com.ryanheise.android_audio_manager');
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (_) async => true);
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());
        const outputLevel = 1.25;
        final restored = Completer<void>();
        late final AudioPlayer player;
        player = AudioPlayer(
          androidApplyAudioAttributes: false,
          onDuckEnd: () async {
            await player.setVolume(outputLevel);
            restored.complete();
          },
        );

        Future<void> focusChanged(AndroidAudioFocus focus) =>
            messenger.handlePlatformMessage(
              channel.name,
              channel.codec.encodeMethodCall(
                MethodCall('onAudioFocusChanged', [focus.index]),
              ),
              (_) {},
            );

        try {
          expect(await session.setActive(true), isTrue);
          await player.setVolume(0.7);
          await focusChanged(AndroidAudioFocus.lossTransientCanDuck);
          await focusChanged(AndroidAudioFocus.gain);
          await restored.future.timeout(const Duration(seconds: 5));
          expect(player.volume, outputLevel);
        } finally {
          await player.dispose();
          await session.setActive(false);
          messenger.setMockMethodCallHandler(channel, null);
        }
      });
    },
    skip: !Platform.isAndroid,
  );

  testWidgets(
    'native player configuration is isolated and survives stop recreation',
    (tester) async {
      await _nativeContract(() async {
        final directory = await Directory.systemTemp.createTemp(
          'kiko-player-configuration-',
        );
        final source = File.fromUri(directory.uri.resolve('configured.wav'));
        await source.writeAsBytes(
          gzip.decode(base64Decode(audioBackendWavGzipBase64)),
        );
        final first = _player();
        final second = _player();
        final firstId = first.platformId;
        final secondId = second.platformId;
        var initialCalls = 0;
        var latestCalls = 0;
        dynamic firstNative;
        dynamic secondNative;
        var activeCallbacks = 0;
        var maxActiveCallbacks = 0;
        final refreshStarted = Completer<void>();
        final releaseRefresh = Completer<void>();
        var forgottenIdInitialized = false;
        try {
          await _configureNativePlayer(firstId, (native) async {
            initialCalls++;
            await native.setProperty('volume-max', '200');
          });
          await _configureNativePlayer(firstId, (native) async {
            latestCalls++;
            firstNative = native;
            await native.setProperty('volume-max', '250');
          });
          await _configureNativePlayer(secondId, (native) async {
            secondNative = native;
            await native.setProperty('volume-max', '300');
          });

          await first.setAudioSource(AudioSource.uri(Uri.file(source.path)));
          await second.setAudioSource(AudioSource.uri(Uri.file(source.path)));
          expect(initialCalls, 0);
          expect(latestCalls, 1);
          expect(
            double.parse(await firstNative!.getProperty('volume-max')),
            250,
          );
          expect(
            double.parse(await secondNative!.getProperty('volume-max')),
            300,
          );

          final earlierRefresh = _configureNativePlayer(firstId, (
            native,
          ) async {
            activeCallbacks++;
            if (activeCallbacks > maxActiveCallbacks) {
              maxActiveCallbacks = activeCallbacks;
            }
            refreshStarted.complete();
            await releaseRefresh.future;
            await native.setProperty('volume-max', '350');
            activeCallbacks--;
          });
          await refreshStarted.future.timeout(const Duration(seconds: 5));
          final latestRefresh = _configureNativePlayer(firstId, (native) async {
            activeCallbacks++;
            if (activeCallbacks > maxActiveCallbacks) {
              maxActiveCallbacks = activeCallbacks;
            }
            latestCalls++;
            firstNative = native;
            await native.setProperty('volume-max', '400');
            activeCallbacks--;
          });
          releaseRefresh.complete();
          await Future.wait([earlierRefresh, latestRefresh]);
          expect(maxActiveCallbacks, 1);
          expect(
            double.parse(await firstNative!.getProperty('volume-max')),
            400,
          );
          expect(
            double.parse(await secondNative!.getProperty('volume-max')),
            300,
          );

          await first.stop();
          await first.setAudioSource(AudioSource.uri(Uri.file(source.path)));
          expect(latestCalls, 3);
          expect(
            double.parse(await firstNative!.getProperty('volume-max')),
            400,
          );
          expect(
            double.parse(await secondNative!.getProperty('volume-max')),
            300,
          );

          await first.dispose();
          JustAudioMediaKit.forgetPlayerConfiguration(firstId);
          await JustAudioPlatform.instance.init(InitRequest(id: firstId));
          forgottenIdInitialized = true;
          expect(latestCalls, 3);
        } finally {
          if (forgottenIdInitialized) {
            await JustAudioPlatform.instance.disposePlayer(
              DisposePlayerRequest(id: firstId),
            );
          }
          await first.dispose();
          await second.dispose();
          JustAudioMediaKit.forgetPlayerConfiguration(firstId);
          JustAudioMediaKit.forgetPlayerConfiguration(secondId);
          await directory.delete(recursive: true);
        }
      });
    },
    skip: !supported,
  );

  testWidgets(
    'native service preloads and advances the actual two-source window',
    (tester) async {
      await _nativeContract(() async {
        final savedPrefetch = JustAudioMediaKit.prefetchPlaylist;
        JustAudioMediaKit.prefetchPlaylist = true;
        final player = _player();
        late AudioPlayerService service;
        final requests = <Map<String, Object>>[];
        final server = await _serveQueue(
          requests,
          () => {
            'native_index': player.currentIndex ?? -1,
            'native_position_ms':
                player.playbackEvent.updatePosition.inMilliseconds,
          },
        );
        SharedPreferences.setMockInitialValues({
          'server_host': 'http://127.0.0.1:${server.port}',
          'current_user': '{"name":"native-contract"}',
          'server_cookie': 'native-contract=yes',
        });
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        SpeculativeTransferCoordinator.instance.resetForTest();
        service = AudioPlayerService.forTesting(
          player,
          nativePlayerId: player.platformId,
          nativePlayerInitializer: Platform.isWindows
              ? _configureWindowsNullAudioOutput
              : null,
          androidNativePreload: true,
          androidSeekRecovery: true,
        );
        service.updatePreloadThreshold(const Duration(seconds: 4));
        await service.updateHapticsSettings(enabled: false, intensity: .85);
        final tracks = [
          for (final id in ['A', 'B', 'C'])
            AudioTrack(
              id: id,
              title: id,
              url: 'http://127.0.0.1:${server.port}/queue/$id.wav',
            ),
        ];
        final published = <String>[];
        final trackSubscription = service.currentTrackStream.listen((track) {
          if (track != null) published.add(track.id);
        });
        final errors = <Object>[];
        final errorSubscription = player.playbackEventStream.listen(
          (_) {},
          onError: errors.add,
        );
        try {
          await service
              .updateQueue(tracks, autoplay: true)
              .timeout(const Duration(seconds: 10));
          await _until(
            () =>
                player.playbackEvent.updatePosition >=
                const Duration(milliseconds: 500),
          );
          var window = player.audioSource! as ConcatenatingAudioSource;
          expect(window.useLazyPreparation, isFalse);
          expect(window.children.length, 1);
          final metrics = <Map<String, Object>>[];
          for (final next in ['B', 'C']) {
            expect(await service.seek(const Duration(seconds: 20)), isTrue);
            await _until(
              () =>
                  player.processingState == ProcessingState.ready &&
                  player.playbackEvent.updatePosition >=
                      const Duration(milliseconds: 100),
            );
            debugPrint(
              'AUDIO_BACKEND_WINDOW ${jsonEncode({'current': service.currentTrack?.id, 'position_ms': player.position.inMilliseconds, 'native_position_ms': player.playbackEvent.updatePosition.inMilliseconds, 'buffered_ms': player.bufferedPosition.inMilliseconds, 'duration_ms': player.duration?.inMilliseconds, 'children': (player.audioSource! as ConcatenatingAudioSource).children.length})}',
            );
            await _until(
              () =>
                  (player.audioSource! as ConcatenatingAudioSource)
                      .children
                      .length ==
                  2,
            );
            window = player.audioSource! as ConcatenatingAudioSource;
            expect(player.currentIndex, 0);
            expect(
              (window.children[1] as UriAudioSource).uri.path,
              '/queue/$next.wav',
            );
            await _until(
              () => requests.any((r) => r['route'] == '/queue/$next.wav'),
            );
            final preparedRequest = requests.firstWhere(
              (r) => r['route'] == '/queue/$next.wav',
            );
            expect(preparedRequest['native_index'], 0);
            expect(preparedRequest['native_position_ms'], greaterThan(0));
            expect(preparedRequest['native_position_ms'], lessThan(24000));
            metrics.add({'next': next, 'prepared_request': preparedRequest});
            expect(await service.seek(const Duration(seconds: 23)), isTrue);
            await _until(
              () =>
                  service.currentTrack?.id == next &&
                  !service.isTrackLoading &&
                  player.processingState == ProcessingState.ready &&
                  player.playing &&
                  player.playbackEvent.updatePosition >=
                      const Duration(milliseconds: 500),
            );
            expect(
              (player.audioSource! as ConcatenatingAudioSource).children.length,
              1,
            );
          }
          expect(published, ['A', 'B', 'C']);
          final requestMarker = requests.length;
          await service.updateQueue([
            tracks[0],
            AudioTrack(
              id: 'B',
              title: 'B16',
              url: 'http://127.0.0.1:${server.port}/queue/B16.wav',
            ),
          ], autoplay: true);
          await _until(
            () =>
                player.playbackEvent.updatePosition >=
                const Duration(milliseconds: 500),
          );
          expect(await service.seek(const Duration(seconds: 20)), isTrue);
          await _until(
            () =>
                (player.audioSource! as ConcatenatingAudioSource)
                        .children
                        .length ==
                    2 &&
                requests
                    .skip(requestMarker)
                    .any((r) => r['route'] == '/queue/B16.wav'),
          );
          await player.setVolume(player.volume);
          final bRequests = requests
              .where((r) => r['route'] == '/queue/B16.wav')
              .length;
          await service.skipToNext().timeout(const Duration(seconds: 10));
          await _until(
            () =>
                service.currentTrack?.id == 'B' &&
                player.processingState == ProcessingState.ready &&
                player.playbackEvent.updatePosition >=
                    const Duration(milliseconds: 500),
          );
          expect(
            requests.where((r) => r['route'] == '/queue/B16.wav').length,
            bRequests,
            reason:
                'Manual next must reuse the fully prefetched source without reopening HTTP',
          );
          expect(
            (player.audioSource! as ConcatenatingAudioSource).children.length,
            1,
          );
          expect(player.duration, const Duration(seconds: 16));
          expect(
            player.bufferedPosition,
            lessThanOrEqualTo(const Duration(seconds: 16)),
          );
          expect(
            player.playbackEvent.updatePosition,
            lessThan(const Duration(seconds: 3)),
          );
          expect(published, ['A', 'B', 'C', 'A', 'B']);
          expect(errors, isEmpty);
          binding.reportData = {
            ...?binding.reportData,
            'native_preload': metrics,
            'gate_status': 'incomplete',
          };
        } finally {
          debugPrint(
            'AUDIO_BACKEND_SERVICE ${jsonEncode(LogService.instance.logs.where((entry) => entry.message.contains('Prepared next') || entry.message.contains('Native next') || entry.message.contains('_loadTrack:')).map((entry) => entry.message).toList())}',
          );
          debugPrint(
            'AUDIO_BACKEND_PRELOAD ${jsonEncode({'published': published, 'requests': requests, 'position_ms': player.playbackEvent.updatePosition.inMilliseconds, 'buffered_ms': player.bufferedPosition.inMilliseconds, 'state': player.processingState.name})}',
          );
          await trackSubscription.cancel();
          await errorSubscription.cancel();
          await service.dispose();
          JustAudioMediaKit.prefetchPlaylist = savedPrefetch;
          SpeculativeTransferCoordinator.instance.resetForTest();
          await server.close(force: true);
        }
      });
    },
    skip: !supported,
  );

  testWidgets('native preload preserves chapter clipping after promotion', (
    tester,
  ) async {
    await _nativeContract(() async {
      final savedPrefetch = JustAudioMediaKit.prefetchPlaylist;
      JustAudioMediaKit.prefetchPlaylist = false;
      final player = _player();
      late AudioPlayerService service;
      final requests = <Map<String, Object>>[];
      final server = await _serveQueue(
        requests,
        () => {
          'native_index': player.currentIndex ?? -1,
          'native_position_ms':
              player.playbackEvent.updatePosition.inMilliseconds,
        },
      );
      SharedPreferences.setMockInitialValues({
        'server_host': 'http://127.0.0.1:${server.port}',
        'current_user': '{"name":"native-contract"}',
        'server_cookie': 'native-contract=yes',
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      SpeculativeTransferCoordinator.instance.resetForTest();
      service = AudioPlayerService.forTesting(
        player,
        nativePlayerId: player.platformId,
        nativePlayerInitializer: Platform.isWindows
            ? _configureWindowsNullAudioOutput
            : null,
        androidNativePreload: true,
        androidSeekRecovery: true,
      );
      service.updatePreloadThreshold(const Duration(seconds: 4));
      final errorSubscription = player.playbackEventStream.listen(
        (_) {},
        onError: (Object error) => fail('Unexpected playback error: $error'),
      );
      final serviceLoadStarts = <PlaybackDiagnosticEvent>[];
      final diagnosticSubscription = service.playbackDiagnosticEventStream
          .where(
            (event) =>
                event.type == PlaybackDiagnosticEventType.trackLoadStarted,
          )
          .listen(serviceLoadStarts.add);
      try {
        await service.updateQueue([
          AudioTrack(
            id: 'A',
            title: 'A',
            url: 'http://127.0.0.1:${server.port}/queue/A.wav',
          ),
          AudioTrack(
            id: 'B',
            title: 'B',
            url: 'http://127.0.0.1:${server.port}/queue/B.wav',
            startTimeMs: 4000,
            endTimeMs: 20000,
          ),
        ], autoplay: true);
        await _until(
          () =>
              player.playbackEvent.updatePosition >=
              const Duration(milliseconds: 500),
        );
        expect(await service.seek(const Duration(seconds: 20)), isTrue);
        await _until(
          () =>
              (player.audioSource! as ConcatenatingAudioSource)
                      .children
                      .length ==
                  2 &&
              requests.any((request) => request['route'] == '/queue/B.wav'),
        );

        final prepared =
            (player.audioSource! as ConcatenatingAudioSource).children[1]
                as ClippingAudioSource;
        expect(prepared.start, const Duration(seconds: 4));
        expect(prepared.end, const Duration(seconds: 20));
        final preparedRequests = requests
            .where((request) => request['route'] == '/queue/B.wav')
            .toList();
        expect(preparedRequests, isNotEmpty);
        expect(preparedRequests.first['native_position_ms'], greaterThan(0));
        await _until(() => service.isNativeNextPreparedForTesting('B'));

        await service.skipToNext().timeout(const Duration(seconds: 10));
        await _until(
          () =>
              service.currentTrack?.id == 'B' &&
              !service.isTrackLoading &&
              player.processingState == ProcessingState.ready &&
              player.playbackEvent.updatePosition >=
                  const Duration(milliseconds: 500),
        );

        expect(player.duration, const Duration(seconds: 16));
        expect(player.position, lessThan(const Duration(seconds: 3)));
        expect(
          player.bufferedPosition,
          lessThanOrEqualTo(const Duration(seconds: 16)),
        );
        expect(
          serviceLoadStarts.where((event) => event.trackKey == 'B'),
          isEmpty,
          reason:
              'Promoting the prepared child must not start a second service load',
        );
        await player.pause();
        final nativeVolumeUpdate = player.volumeStream.skip(2).first;
        await player.setVolume(4);
        expect(
          await nativeVolumeUpdate.timeout(const Duration(seconds: 5)),
          closeTo(4, 0.01),
          reason: 'The service must raise MPV volume-max before volume updates',
        );
        await player.setVolume(1);
      } finally {
        debugPrint(
          'AUDIO_BACKEND_CHAPTER_PROMOTION ${jsonEncode({'duration_ms': player.duration?.inMilliseconds, 'position_ms': player.position.inMilliseconds, 'service_load_started': serviceLoadStarts.map((event) => event.trackKey).toList(), 'requests': requests.where((request) => request['route'] == '/queue/B.wav').toList(), 'native_load_logs': LogService.instance.logs.where((entry) => entry.message.contains('Prepared next') || entry.message.contains('Native next')).map((entry) => entry.message).toList()})}',
        );
        await service.dispose();
        await diagnosticSubscription.cancel();
        await errorSubscription.cancel();
        await server.close(force: true);
        JustAudioMediaKit.prefetchPlaylist = savedPrefetch;
      }
    });
  }, skip: !supported);

  testWidgets('native service keeps C after a real in-flight A B C switch', (
    tester,
  ) async {
    await _nativeContract(() async {
      final player = _player();
      final requests = <Map<String, Object>>[];
      final bRequested = Completer<void>();
      final releaseB = Completer<void>();
      final server = await _serveQueue(
        requests,
        () => {
          'native_index': player.currentIndex ?? -1,
          'native_position_ms':
              player.playbackEvent.updatePosition.inMilliseconds,
        },
        bRequested: bRequested,
        releaseB: releaseB.future,
      );
      SharedPreferences.setMockInitialValues({
        'server_host': 'http://127.0.0.1:${server.port}',
        'current_user': '{"name":"native-contract"}',
        'server_cookie': 'native-contract=yes',
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      SpeculativeTransferCoordinator.instance.resetForTest();
      final service = AudioPlayerService.forTesting(
        player,
        nativePlayerId: player.platformId,
        nativePlayerInitializer: Platform.isWindows
            ? _configureWindowsNullAudioOutput
            : null,
        androidNativePreload: true,
        androidSeekRecovery: true,
      );
      service.updatePreloadThreshold(null);
      final tracks = [
        for (final id in ['A', 'B', 'C'])
          AudioTrack(
            id: id,
            title: id,
            url: 'http://127.0.0.1:${server.port}/queue/$id.wav',
          ),
      ];
      final published = <String>[];
      final trackSubscription = service.currentTrackStream.listen((track) {
        if (track != null) published.add(track.id);
      });
      final errors = <Object>[];
      final errorSubscription = player.playbackEventStream.listen(
        (_) {},
        onError: errors.add,
      );
      try {
        await service.updateQueue(tracks, autoplay: true);
        await _until(
          () =>
              player.playbackEvent.updatePosition >=
              const Duration(milliseconds: 500),
        );
        final b = service.skipToIndex(1);
        await bRequested.future.timeout(const Duration(seconds: 10));
        final c = service.skipToIndex(2);
        await Future.wait([b, c]).timeout(const Duration(seconds: 10));
        expect(service.currentTrack?.id, 'C');
        await _until(
          () =>
              !service.isTrackLoading &&
              player.playing &&
              player.processingState == ProcessingState.ready &&
              player.playbackEvent.updatePosition >=
                  const Duration(milliseconds: 500),
        );
        releaseB.complete();
        await _until(
          () =>
              player.playbackEvent.updatePosition >=
              const Duration(milliseconds: 1000),
        );
        expect(service.currentTrack?.id, 'C');
        expect(
          (player.sequenceState!.currentSource as UriAudioSource).uri.path,
          '/queue/C.wav',
        );
        expect(published, ['A', 'C']);
        expect(errors, isEmpty);
        binding.reportData = {
          ...?binding.reportData,
          'latest_wins': {'published': published, 'requests': requests},
          'gate_status': 'incomplete',
        };
      } finally {
        if (!releaseB.isCompleted) releaseB.complete();
        debugPrint(
          'AUDIO_BACKEND_LATEST ${jsonEncode({'published': published, 'requests': requests, 'current': service.currentTrack?.id})}',
        );
        await trackSubscription.cancel();
        await errorSubscription.cancel();
        await service.dispose();
        SpeculativeTransferCoordinator.instance.resetForTest();
        await server.close(force: true);
      }
    });
  }, skip: !supported);

  testWidgets(
    'native transition failure returns and a later C load advances',
    (tester) async {
      expect(
        PerformanceBuildGuard.enabled,
        isTrue,
        reason:
            'Run this contract with --dart-define=KIKOFLU_PERFORMANCE=true to observe service failure diagnostics.',
      );
      final player = _player();
      final requests = <Map<String, Object>>[];
      final server = await _serveQueue(
        requests,
        () => {
          'native_index': player.currentIndex ?? -1,
          'native_position_ms':
              player.playbackEvent.updatePosition.inMilliseconds,
        },
      );
      final failureUri = 'http://127.0.0.1:${server.port}/queue/missing-B.wav';
      final savedPrefetch = JustAudioMediaKit.prefetchPlaylist;
      JustAudioMediaKit.prefetchPlaylist = true;
      await _nativeContract(() async {
        SharedPreferences.setMockInitialValues({
          'server_host': 'http://127.0.0.1:${server.port}',
          'current_user': '{"name":"native-contract"}',
          'server_cookie': 'native-contract=yes',
        });
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        SpeculativeTransferCoordinator.instance.resetForTest();
        final service = AudioPlayerService.forTesting(
          player,
          nativePlayerId: player.platformId,
          nativePlayerInitializer: Platform.isWindows
              ? _configureWindowsNullAudioOutput
              : null,
          androidNativePreload: true,
          androidSeekRecovery: true,
        );
        service.updatePreloadThreshold(const Duration(seconds: 4));
        final failures = <PlaybackDiagnosticEvent>[];
        final diagnosticSubscription = service.playbackDiagnosticEventStream
            .listen((event) {
              if (event.type == PlaybackDiagnosticEventType.trackLoadFailed &&
                  event.trackKey == 'B') {
                failures.add(event);
              }
            });
        final errors = <Object>[];
        final subscription = player.playbackEventStream.listen(
          (_) {},
          onError: errors.add,
        );
        try {
          await service.updateQueue([
            for (final id in ['A', 'B', 'C'])
              AudioTrack(
                id: id,
                title: id,
                url: id == 'B'
                    ? failureUri
                    : 'http://127.0.0.1:${server.port}/queue/$id.wav',
              ),
          ], autoplay: true);
          await _until(
            () =>
                player.playbackEvent.updatePosition >=
                const Duration(milliseconds: 500),
          );
          expect(await service.seek(const Duration(seconds: 20)), isTrue);
          await _until(
            () =>
                requests.any(
                  (request) => request['route'] == '/queue/missing-B.wav',
                ) &&
                player.playbackEvent.updatePosition >=
                    const Duration(seconds: 21),
          );
          expect(service.currentTrack?.id, 'A');
          expect(player.playing, isTrue);
          expect(await service.seek(const Duration(seconds: 23)), isTrue);
          await _until(() => failures.isNotEmpty);
          expect(failures.first.detail, isNotNull);
          expect(
            errors.every((error) => error.toString().contains(failureUri)),
            isTrue,
          );
          await service.skipToIndex(2).timeout(const Duration(seconds: 10));
          await _until(
            () =>
                service.currentTrack?.id == 'C' &&
                !service.isTrackLoading &&
                player.playing &&
                player.processingState == ProcessingState.ready &&
                player.playbackEvent.updatePosition >=
                    const Duration(milliseconds: 500),
          );
          binding.reportData = {
            ...?binding.reportData,
            'failed_transition': {
              'error_count': errors.length,
              'service_failure_count': failures.length,
              'current': 'C',
            },
            'gate_status': 'incomplete',
          };
        } finally {
          debugPrint(
            'AUDIO_BACKEND_FAILURE ${jsonEncode({'errors': errors.map((e) => e.toString()).toList(), 'requests': requests, 'current': service.currentTrack?.id, 'state': player.processingState.name})}',
          );
          await diagnosticSubscription.cancel();
          await subscription.cancel();
          await service.dispose();
          JustAudioMediaKit.prefetchPlaylist = savedPrefetch;
          SpeculativeTransferCoordinator.instance.resetForTest();
          await server.close(force: true);
        }
      }, expectedOpenFailure: failureUri);
    },
    skip: !supported,
  );
}

AudioPlayer _player() => AudioPlayer(
  useProxyForRequestHeaders: false,
  handleInterruptions: false,
  handleAudioSessionActivation: false,
  androidApplyAudioAttributes: false,
);

Future<AudioPlayer> _configuredPlayer() async {
  final player = _player();
  if (Platform.isWindows) {
    await _configureNativePlayer(player.platformId, (_) async {});
  }
  return player;
}

Future<void> _configureNativePlayer(
  String id,
  NativePlayerConfiguration configure,
) => JustAudioMediaKit.configurePlayer(id, (native) async {
  await configure(native);
  await _configureWindowsNullAudioOutput(native);
});

Future<void> _configureWindowsNullAudioOutput(NativePlayer native) async {
  if (!Platform.isWindows) return;
  await native.setProperty('ao', 'null');
  await native.setProperty('audio-exclusive', 'no');
  expect(await native.getProperty('options/ao'), 'null');
}

bool _emptySeekTable(Uint8List bytes) {
  var offset = 4;
  while (offset < bytes.length) {
    final type = bytes[offset] & 127;
    final size =
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    if (type == 3 && size == 0) return true;
    if (bytes[offset] & 128 != 0) return false;
    offset += 4 + size;
  }
  return false;
}

Future<void> _until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 10)) {
      throw TimeoutException('Native playback condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Future<void> _nativeContract(
  Future<void> Function() body, {
  String? expectedOpenFailure,
}) async {
  final nativeErrors = <String>[];
  await runZoned(
    () async {
      await body();
      if (expectedOpenFailure == null) {
        expect(
          nativeErrors,
          isEmpty,
          reason: 'Native adapter errors cannot count as a pass',
        );
      } else {
        expect(nativeErrors, isNotEmpty);
        expect(
          nativeErrors.every(
            (line) =>
                line.contains('HTTP error 404') ||
                line.contains('Failed to open $expectedOpenFailure.') ||
                line == 'MPV: [error] ytdl_hook: Subprocess failed: init' ||
                line ==
                    'MPV: [error] ytdl_hook: youtube-dl failed: not found or not enough permissions' ||
                line == 'MPV: [error] ytdl_hook: ',
          ),
          isTrue,
          reason: 'Only the deliberately rejected B origin may fail',
        );
      }
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        if (RegExp(r'MPV: \[(error|fatal)\]|error:').hasMatch(line)) {
          nativeErrors.add(line);
        }
        parent.print(zone, line);
      },
    ),
  );
}

const _route = '/protected/nested/voice%20A.wav?route=one';
const _authorization = 'Bearer native-contract';

Future<HttpServer> _serveAuthenticatedAudio(
  List<Map<String, Object>> requests,
) async {
  final bytes = gzip.decode(base64Decode(audioBackendWavGzipBase64));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final range = request.headers.value(HttpHeaders.rangeHeader) ?? '';
    final authorization =
        request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    requests.add({
      'route': request.uri.toString(),
      'authorization': authorization,
      'range': range,
    });
    final response = request.response;
    if (request.uri.toString() != _route || authorization != _authorization) {
      response.statusCode = authorization == _authorization
          ? HttpStatus.notFound
          : HttpStatus.unauthorized;
      await response.close();
      return;
    }
    await _sendWav(request, bytes);
  });
  return server;
}

Future<void> _sendWav(HttpRequest request, List<int> bytes) async {
  final response = request.response;
  final range = request.headers.value(HttpHeaders.rangeHeader) ?? '';
  response.headers.contentType = ContentType('audio', 'wav');
  response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  var start = 0;
  var end = bytes.length - 1;
  if (range.isNotEmpty) {
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
    start = int.parse(match.group(1)!);
    if (match.group(2)!.isNotEmpty) end = int.parse(match.group(2)!);
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/${bytes.length}',
    );
  }
  response.contentLength = end - start + 1;
  if (request.method != 'HEAD') response.add(bytes.sublist(start, end + 1));
  await response.close();
}

List<int> _shortWav(List<int> wav) {
  final bytes = Uint8List.fromList(wav.sublist(0, 44 + 16 * 16000 * 2));
  final header = ByteData.sublistView(bytes);
  header.setUint32(4, bytes.length - 8, Endian.little);
  header.setUint32(40, bytes.length - 44, Endian.little);
  return bytes;
}

Future<HttpServer> _serveQueue(
  List<Map<String, Object>> requests,
  Map<String, Object> Function() playback, {
  Completer<void>? bRequested,
  Future<void>? releaseB,
}) async {
  final bytes = gzip.decode(base64Decode(audioBackendWavGzipBase64));
  final shorter = _shortWav(bytes);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final cookie = request.headers.value(HttpHeaders.cookieHeader) ?? '';
    requests.add({
      'route': request.uri.toString(),
      'cookie': cookie,
      'range': request.headers.value(HttpHeaders.rangeHeader) ?? '',
      ...playback(),
    });
    if (request.uri.path == '/queue/missing-B.wav' &&
        cookie == 'native-contract=yes') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (![
          '/queue/A.wav',
          '/queue/B.wav',
          '/queue/B16.wav',
          '/queue/C.wav',
        ].contains(request.uri.path) ||
        cookie != 'native-contract=yes') {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    if (request.uri.path == '/queue/B.wav' && bRequested != null) {
      if (!bRequested.isCompleted) bRequested.complete();
      await releaseB;
    }
    try {
      await _sendWav(
        request,
        request.uri.path == '/queue/B16.wav' ? shorter : bytes,
      );
    } on SocketException {
      // A cancelled B load closes its real HTTP connection before release.
    } on HttpException {
      // The client can dispose the held B response when C supersedes it.
    }
  });
  return server;
}
