import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/main.dart' as app;
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/performance/performance_fixture_manifest.dart';
import 'package:kikoeru_flutter/src/performance/performance_recorder.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/background_work_scheduler.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/screen_awake_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:kikoeru_flutter/src/widgets/image_gallery_screen.dart';

/// Uses the production widgets, route and audio backend. Files and run controls
/// are supplied through the test application's external-files directory.
void main() {
  final startup = Stopwatch()..start();
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('Android player Profile', (tester) async {
    const root =
        '/sdcard/Android/data/com.meteor.kikoeruflutter/files/'
        'player_performance';
    final control =
        jsonDecode(await File('$root/control.json').readAsString())
            as Map<String, dynamic>;
    final runNumber = (control['run'] as num).toInt();
    final label = control['label'] as String;
    final reportFile = File('$root/${label}_$runNumber.json');
    final recorder = PerformanceRecorder.instance
      ..start(force: true)
      ..resetRun();
    final samples = <Map<String, Object?>>[];
    final checks = <Map<String, Object?>>[];
    final positions = StreamController<Duration>.broadcast();
    final tracks = StreamController<AudioTrack?>();
    var presentationRevision = 0;
    final service = AudioPlayerService.instance;
    final navigator = GlobalKey<NavigatorState>();
    Object? failure;
    try {
      app.main(const []);
      await _wait(tester, () => recorder.metric('firstInteractiveMs') != null);
      recorder.recordMetric('coldStartMs', startup.elapsedMicroseconds / 1000);
      await BackgroundWorkScheduler.instance.whenIdle();
      await ScreenAwakeService.setEnabled(true);
      await (await StorageService.getPrefs()).setBool(
        'lyric_hint_has_shown',
        true,
      );
      await service.clearQueue();
      await service.updateHapticsSettings(enabled: false, intensity: 0.85);
      recorder.setRefreshRate(tester.view.display.refreshRate);

      final cover = File('$root/cover.png');
      final coverBytes = await rootBundle.load(
        'assets/icons/app_icon_opaque.png',
      );
      await cover.writeAsBytes(coverBytes.buffer.asUint8List());
      final visualTrack = AudioTrack(
        id: 'profile-visual',
        title: '播放器性能测试 · 日本語のタイトル',
        artist: 'Player Profile',
        url: 'file://$root/fixtures/small_a.wav',
        artworkUrl: cover.uri.toString(),
      );
      tracks.add(visualTrack);
      final otherCover = File('$root/other_cover.png');
      await otherCover.writeAsBytes(coverBytes.buffer.asUint8List());
      final lyrics = List.generate(
        500,
        (index) => LyricLine(
          startTime: Duration(seconds: index),
          endTime: Duration(seconds: index + 1),
          text: '字幕 $index · 同じ景色を見ながら、ゆっくり歩いていく。',
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('player-profile'),
          overrides: [
            currentTrackProvider.overrideWith((ref) => tracks.stream),
            playerTrackChangePresentationProvider.overrideWith((ref) {
              final current = ref.watch(currentTrackProvider).value;
              return current == null
                  ? null
                  : PlayerTrackChangePresentation(
                      trackId: current.id,
                      direction: presentationRevision.isEven
                          ? PlayerTrackChangeDirection.next
                          : PlayerTrackChangeDirection.previous,
                      revision: presentationRevision,
                    );
            }),
            isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
            positionProvider.overrideWith((ref) => positions.stream),
            durationProvider.overrideWith(
              (ref) => Stream.value(const Duration(seconds: 500)),
            ),
            playerStateProvider.overrideWith(
              (ref) => Stream.value(PlayerState(true, ProcessingState.ready)),
            ),
            queueProvider.overrideWith((ref) => Stream.value([visualTrack])),
            manualSkipAvailabilityProvider.overrideWith(
              (ref) => Stream.value(ManualSkipAvailability.unavailable),
            ),
            lyricAutoLoaderProvider.overrideWith((ref) {}),
            lyricControllerProvider.overrideWith(
              (ref) => LyricController(
                ref,
                initialState: LyricState(lyrics: lyrics),
              ),
            ),
          ],
          child: MaterialApp(
            navigatorKey: navigator,
            locale: const Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            theme: ThemeData.dark(useMaterial3: true),
            home: const Scaffold(
              body: Center(child: Text('Player Profile')),
              bottomNavigationBar: MiniPlayer(),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      final cycles = (control['cycles'] as num?)?.toInt() ?? 4;
      final launcher = find.byKey(
        const ValueKey('mini-player-upward-launcher'),
      );
      final pages = find.byKey(const ValueKey('compact-player-pages'));
      Future<void> beginScene(String name) async {
        // Read Android's current mode: Flutter's Display can retain the launch
        // refresh rate while the device switches its adaptive display mode.
        final refreshRate = await const MethodChannel(
          'com.meteor.kikoeruflutter/performance',
        ).invokeMethod<double>('getDisplayRefreshRate');
        recorder
          ..setRefreshRate(refreshRate ?? tester.view.display.refreshRate)
          ..beginScenario(name);
      }

      if (control['ui'] != false) {
        await beginScene('expandCold');
        await tester.tap(launcher);
        await tester.pump(const Duration(milliseconds: 650));
        recorder.endScenario();
        navigator.currentState!.pop();
        await tester.pump(const Duration(milliseconds: 650));

        await beginScene('expandCollapse');
        for (var i = 0; i < cycles; i++) {
          await tester.tap(launcher);
          await tester.pump(const Duration(milliseconds: 550));
          navigator.currentState!.pop();
          await tester.pump(const Duration(milliseconds: 550));
        }
        recorder.endScenario();

        await beginScene('dragRebound');
        for (var i = 0; i < cycles; i++) {
          final gesture = await tester.startGesture(tester.getCenter(launcher));
          await gesture.moveBy(const Offset(0, -120));
          await tester.pump(const Duration(milliseconds: 100));
          await gesture.moveBy(const Offset(0, 60));
          await tester.pump(const Duration(milliseconds: 100));
          await gesture.cancel();
          await tester.pump(const Duration(milliseconds: 550));
        }
        recorder.endScenario();

        await beginScene('dragHandoff');
        for (var i = 0; i < cycles; i++) {
          final gesture = await tester.startGesture(tester.getCenter(launcher));
          for (var step = 0; step < 14; step++) {
            await gesture.moveBy(const Offset(0, -16));
            await tester.pump(const Duration(milliseconds: 16));
          }
          await gesture.up();
          await tester.pump(const Duration(milliseconds: 550));
          await tester.drag(
            find.byKey(const ValueKey('compact-header-dismiss-surface')),
            const Offset(0, 300),
          );
          await tester.pump(const Duration(milliseconds: 550));
        }
        recorder.endScenario();
        await tester.tap(launcher);
        await tester.pump(const Duration(milliseconds: 650));

        await beginScene('rapidTrackPresentation');
        for (var i = 0; i < 40; i++) {
          presentationRevision++;
          tracks.add(
            visualTrack.copyWith(
              id: 'visual-$i',
              title: 'Track $i - animated presentation',
              artworkUrl: (i.isEven ? cover : otherCover).uri.toString(),
              workId: 10000 + i,
            ),
          );
          await tester.pump(const Duration(milliseconds: 45));
        }
        await tester.pump(const Duration(milliseconds: 600));
        recorder.endScenario();
        presentationRevision++;
        tracks.add(visualTrack);
        await tester.pump(const Duration(milliseconds: 600));
        await beginScene('pageSwitch');
        for (var i = 0; i < cycles; i++) {
          for (final dx in [-300.0, 300.0, 300.0, -300.0]) {
            await tester.drag(pages, Offset(dx, 0));
            await tester.pump(const Duration(milliseconds: 400));
          }
        }
        recorder.endScenario();
        await tester.drag(pages, const Offset(-300, 0));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byKey(const ValueKey('full-lyric-list')), findsOneWidget);
        await beginScene('lyricFollow');
        for (var i = 1; i <= 20; i++) {
          positions.add(Duration(seconds: i));
          await tester.pump(const Duration(milliseconds: 350));
        }
        recorder.endScenario();
        await beginScene('lyricScroll');
        for (var i = 0; i < cycles; i++) {
          await tester.fling(
            find.byKey(const ValueKey('full-lyric-list')),
            const Offset(0, -450),
            1200,
          );
          await tester.pump(const Duration(milliseconds: 500));
        }
        recorder.endScenario();
        navigator.currentState!.pop();
        await tester.pump(const Duration(milliseconds: 650));
      }

      if (control['ui'] != false) {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: ImageGalleryScreen(
              images: [
                {'url': cover.uri.toString(), 'title': 'Animation fixture'},
              ],
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await beginScene('galleryDoubleTap');
        final viewer = find.byType(InteractiveViewer);
        for (var i = 0; i < 12; i++) {
          await tester.tapAt(tester.getCenter(viewer) + const Offset(45, 30));
          await tester.pump(const Duration(milliseconds: 50));
          await tester.tapAt(tester.getCenter(viewer) + const Offset(45, 30));
          await tester.pump(const Duration(milliseconds: 350));
        }
        recorder.endScenario();
      }
      if (control['audio'] != false) {
        const manifestPath = '$root/fixtures/manifest.json';
        final manifest = await PerformanceAudioFixtureManifest.read(
          File(manifestPath),
        );
        final tracks = <AudioTrack>[];
        for (final fixture in manifest.tracks) {
          var path = manifest.resolvePath(manifestPath, fixture);
          if (fixture.mode == 'cache') {
            final hash = fixture.hash!;
            final source = File(path);
            final cached = await CacheService.getCachedAudioFile(hash);
            if (cached == null) {
              final partial = await CacheService.prepareAudioCacheTempFile(
                hash,
              );
              await source.copy(partial.path);
              expect(
                await CacheService.finalizeAudioCacheFile(
                  hash,
                  expectedSize: await source.length(),
                ),
                isTrue,
              );
            }
            path = await CacheService.audioCacheFinalPath(hash);
          }
          tracks.add(
            AudioTrack(
              id: fixture.id,
              title: fixture.title,
              url: Uri.file(path).toString(),
              hash: fixture.hash,
            ),
          );
        }
        await service.updateQueue(tracks);
        await service.play();
        await service.setRepeatMode(LoopMode.off);
        final repeats = (control['audioRepeats'] as num?)?.toInt() ?? 2;
        final small = manifest.tracks.indexWhere(
          (track) => track.sizeClass == 'small',
        );
        for (var repeat = 0; repeat < repeats; repeat++) {
          for (var i = 0; i < tracks.length; i++) {
            await service.skipToIndex(i);
            await _waitForPlayback(tester, service, tracks[i].id);
            await tester.pump(const Duration(milliseconds: 700));
            final target = i == small ? small + 1 : small;
            final watch = Stopwatch()..start();
            if (control['stopBeforeSwitch'] == true) await service.stop();
            await service.skipToIndex(target);
            await _waitForPlayback(tester, service, tracks[target].id);
            samples.add({
              'from': tracks[i].id,
              'to': tracks[target].id,
              'mode': manifest.tracks[i].mode,
              'sizeClass': manifest.tracks[i].sizeClass,
              'elapsedMs': watch.elapsedMicroseconds / 1000,
            });
          }
        }

        // Exercise cancellation while preparing a large file and while replacing
        // a native source. Baseline records the outcome without hiding a race.
        if (control['raceChecks'] != false) {
          for (final i in [0, 1, 2, 3]) {
            await service.skipToIndex(small);
            await _waitForPlayback(tester, service, tracks[small].id);
            final errors = <String>[];
            final published = <String>[];
            final publicationSubscription = service.currentTrackStream.listen((
              track,
            ) {
              if (track != null) published.add(track.id);
            });
            Future<void> capture(Future<void> operation) => operation
                .timeout(const Duration(seconds: 15))
                .catchError((Object error) {
                  errors.add(error.toString());
                });
            try {
              final first = capture(service.skipToIndex(i));
              await tester.pump(const Duration(milliseconds: 10));
              final second = capture(service.skipToIndex(small + 1));
              final cancellationWatch = Stopwatch()..start();
              final third = capture(service.skipToIndex(small + 2));
              await Future.wait([first, second, third]);
              if (service.currentTrack?.id == tracks[small + 2].id) {
                await _waitForPlayback(tester, service, tracks[small + 2].id);
              }
              final cancellationMs =
                  cancellationWatch.elapsedMicroseconds / 1000;
              await tester.pump(const Duration(seconds: 1));
              final fixture = manifest.tracks[i];
              checks.add({
                'case': 'latest-${fixture.id}',
                'actual': service.currentTrack?.id,
                'expected': tracks[small + 2].id,
                'published': List<String>.of(published),
                'errors': errors,
                'latestToPositionMs': cancellationMs,
                'cachePreserved':
                    fixture.hash == null ||
                    await CacheService.getCachedAudioFile(fixture.hash!) !=
                        null,
              });
            } finally {
              await publicationSubscription.cancel();
            }
          }
        }
        if (control['seekChecks'] == true) {
          // Use live playback providers so the production Slider, controller,
          // persistence path and native player participate in the same seek.
          await tester.pumpWidget(
            ProviderScope(
              key: const ValueKey('player-seek-profile'),
              overrides: [lyricAutoLoaderProvider.overrideWith((ref) {})],
              child: MaterialApp(
                navigatorKey: navigator,
                locale: const Locale('en'),
                localizationsDelegates: S.localizationsDelegates,
                supportedLocales: S.supportedLocales,
                theme: ThemeData.dark(useMaterial3: true),
                home: const Scaffold(bottomNavigationBar: MiniPlayer()),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          await tester.tap(launcher);
          await tester.pump(const Duration(milliseconds: 650));
          for (var i = 0; i < tracks.length; i++) {
            if (manifest.tracks[i].sizeClass != 'large') continue;
            await service.skipToIndex(i);
            await _waitForPlayback(tester, service, tracks[i].id);
            await tester.pump(const Duration(seconds: 1));
            final duration = service.duration;
            if (duration == null || duration <= const Duration(seconds: 10)) {
              throw StateError('Large audio fixture has no usable duration');
            }
            for (final fraction in [0.25, 0.80, 0.10]) {
              final check = await _checkSeekPlayback(
                tester,
                service,
                tracks[i].id,
                Duration(
                  milliseconds: (duration.inMilliseconds * fraction).round(),
                ),
              );
              checks.add(check);
              if (check['passed'] != true) {
                throw StateError('Seek did not resume for ${tracks[i].id}');
              }
            }
          }
        }
        final soak = (control['soakSeconds'] as num?)?.toInt() ?? 0;
        if (soak > 0) {
          final soakIndex = (control['soakIndex'] as num?)?.toInt() ?? 0;
          await service.skipToIndex(soakIndex);
          await _waitForPlayback(tester, service, tracks[soakIndex].id);
          final startPosition = service.position;
          await tester.pump(Duration(seconds: soak));
          checks.add({
            'case': 'continuousPlayback',
            'playing': service.playing,
            'positionMs': service.position.inMilliseconds,
            'advancedMs': (service.position - startPosition).inMilliseconds,
            'expectedSeconds': soak,
          });
        }
        await service.clearQueue();
      }
      // FrameTiming callbacks may be batched after the scene's last frame.
      await tester.pump(const Duration(seconds: 2));
    } catch (error, stack) {
      failure = error;
      checks.add({
        'case': 'harnessFailure',
        'error': error.toString(),
        'stack': stack.toString(),
      });
    } finally {
      recorder.endScenario();
      final report = <String, Object?>{
        'schemaVersion': 1,
        'scenario': 'real-android-player-v1',
        'control': control,
        'run': recorder.createRun(run: runNumber),
        'switchSamples': samples,
        'checks': checks,
        'hapticsEnabled': false,
      };
      await reportFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
      binding.reportData = report;
      await ScreenAwakeService.setEnabled(false);
      await positions.close();
      await tracks.close();
    }
    expect(failure, isNull);
    if (control['enforceLatest'] == true) {
      for (final check in checks.where(
        (check) => check.containsKey('expected'),
      )) {
        expect(check['actual'], check['expected']);
        expect((check['published'] as List).last, check['expected']);
        final staleId = check['case'].toString().replaceFirst('latest-', '');
        if (staleId != check['expected']) {
          expect(check['published'], isNot(contains(staleId)));
        }
        expect(check['errors'], isEmpty);
        expect(check['cachePreserved'], isTrue);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}

Future<Map<String, Object?>> _checkSeekPlayback(
  WidgetTester tester,
  AudioPlayerService service,
  String trackId,
  Duration target,
) async {
  final watch = Stopwatch()..start();
  final events = <Map<String, Object?>>[];
  Map<String, Object?> snapshot() => {
    'elapsedMs': watch.elapsedMilliseconds,
    'trackId': service.currentTrack?.id,
    'positionMs': service.position.inMilliseconds,
    'durationMs': service.duration?.inMilliseconds,
    'playing': service.playing,
    'processingState': service.playerState.processingState.name,
    'loading': service.isTrackLoading,
  };
  final subscription = service.playerStateStream.listen((_) {
    events.add(snapshot());
  });
  final check = <String, Object?>{
    'case': 'seek-$trackId',
    'input': 'player-progress-slider',
    'targetMs': target.inMilliseconds,
    'before': snapshot(),
    'passed': false,
  };
  service.debugClearPlaybackDiagnostics();
  try {
    final slider = find.byKey(const ValueKey('player-progress-slider'));
    final sliderWidget = tester.widget<Slider>(slider);
    final theme = SliderTheme.of(tester.element(slider));
    // The production slider's zero padding makes its track span these bounds.
    expect(theme.padding, EdgeInsets.zero);
    final track = tester.getRect(slider);
    Offset point(double fraction) =>
        Offset(track.left + track.width * fraction, track.center.dy);
    final gesture = await tester.startGesture(point(sliderWidget.value));
    await gesture.moveTo(
      point(target.inMilliseconds / service.duration!.inMilliseconds),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    final resumeWatch = Stopwatch()..start();
    // Seek, recovery stop, prepare, and cancellation each have an 8s budget.
    while (resumeWatch.elapsed < const Duration(seconds: 35)) {
      await tester.pump(const Duration(milliseconds: 50));
      if (service.currentTrack?.id == trackId &&
          service.playing &&
          service.playerState.processingState == ProcessingState.ready &&
          service.position >= target + const Duration(milliseconds: 500)) {
        break;
      }
    }
    check['positionAdvancingMs'] = watch.elapsedMilliseconds;
    final resumedPosition = service.position;
    await tester.pump(const Duration(seconds: 1));
    final advanced = service.position - resumedPosition;
    check['advancedAfterSeekMs'] = advanced.inMilliseconds;
    check['passed'] =
        service.currentTrack?.id == trackId &&
        service.playing &&
        service.playerState.processingState == ProcessingState.ready &&
        resumedPosition >= target + const Duration(milliseconds: 500) &&
        resumedPosition < target + const Duration(seconds: 5) &&
        advanced >= const Duration(milliseconds: 700);
  } catch (error, stack) {
    check['errorType'] = error.runtimeType.toString();
    check['error'] = error.toString();
    check['stack'] = stack.toString();
  } finally {
    check['after'] = snapshot();
    check['stateEvents'] = events;
    check['diagnostics'] = service.debugPlaybackDiagnostics
        .map((event) => event.toJson())
        .toList();
    await subscription.cancel();
  }
  return check;
}

Future<void> _wait(WidgetTester tester, bool Function() predicate) async {
  final watch = Stopwatch()..start();
  while (!predicate()) {
    if (watch.elapsed > const Duration(seconds: 45)) {
      throw TimeoutException('Player Profile wait');
    }
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<void> _waitForPlayback(
  WidgetTester tester,
  AudioPlayerService service,
  String id,
) async {
  final initialPosition = service.position;
  var advanced = false;
  final subscription = service.positionStream.listen((position) {
    if (service.currentTrack?.id == id && position > initialPosition) {
      advanced = true;
    }
  });
  try {
    await _wait(
      tester,
      () =>
          service.currentTrack?.id == id &&
          service.playing &&
          service.playerState.processingState == ProcessingState.ready &&
          advanced,
    );
  } finally {
    await subscription.cancel();
  }
}
