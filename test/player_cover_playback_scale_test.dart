import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/artwork_theme_provider.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/cover_preview_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = AudioTrack(
  id: 'cover-scale-track',
  title: 'Cover scale',
  url: 'https://example.invalid/audio.mp3',
  artworkUrl: 'file://assets/icons/app_icon_opaque.png',
);

class _AudioService extends AudioPlayerService {
  _AudioService(this.state) : super.forTesting(AudioPlayer());

  PlayerState state;
  bool loading = false;
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final loadingStates = StreamController<bool>.broadcast(sync: true);

  @override
  PlayerState get playerState => state;
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  bool get isTrackLoading => loading;
  @override
  Stream<bool> get trackLoadingStream => loadingStates.stream;

  void setState(bool playing, ProcessingState processing) {
    state = PlayerState(playing, processing);
    states.add(state);
  }

  void setLoading(bool value) {
    loading = value;
    loadingStates.add(value);
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    await states.close();
    await loadingStates.close();
  }
}

Future<void> _pumpPlayer(
  WidgetTester tester,
  _AudioService service, {
  required Size size,
  required ValueNotifier<bool> disableAnimations,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        audioPlayerServiceProvider.overrideWith((ref) {
          ref.onDispose(() => unawaited(service.dispose()));
          return service;
        }),
        currentTrackProvider.overrideWith((ref) => Stream.value(_track)),
        queueProvider.overrideWith((ref) => Stream.value(const [_track])),
        manualSkipAvailabilityProvider.overrideWith(
          (ref) => Stream.value(ManualSkipAvailability.unavailable),
        ),
        lyricAutoLoaderProvider.overrideWith((ref) {}),
        themeArtworkDescriptorProvider.overrideWith((ref) => null),
      ],
      child: MaterialApp(
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        builder: (context, child) => ValueListenableBuilder<bool>(
          valueListenable: disableAnimations,
          builder: (context, disabled, _) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: disabled),
            child: child!,
          ),
        ),
        home: const AudioPlayerScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

double _coverScale(WidgetTester tester) {
  final cover = find.byKey(
    const ValueKey('player-cover-artwork-cover-scale-track'),
  );
  return tester.getRect(cover).width / tester.getSize(cover).width;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  for (final size in [const Size(390, 844), const Size(1100, 800)]) {
    testWidgets('cover follows playback and loading at $size', (tester) async {
      final service = _AudioService(PlayerState(true, ProcessingState.ready));
      final disabled = ValueNotifier(false);
      addTearDown(disabled.dispose);
      await _pumpPlayer(
        tester,
        service,
        size: size,
        disableAnimations: disabled,
      );
      expect(_coverScale(tester), closeTo(1, 0.001));

      service.setState(false, ProcessingState.ready);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final midway = _coverScale(tester);
      expect(midway, lessThan(1));
      service.setState(true, ProcessingState.ready);
      await tester.pump();
      expect(_coverScale(tester), closeTo(midway, 0.001));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_coverScale(tester), closeTo(1, 0.001));

      service.setState(true, ProcessingState.loading);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_coverScale(tester), closeTo(0.9, 0.001));
      service.setState(true, ProcessingState.buffering);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_coverScale(tester), closeTo(0.9, 0.001));
      service.setState(true, ProcessingState.ready);
      service.setLoading(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_coverScale(tester), closeTo(0.9, 0.001));
      service.setLoading(false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_coverScale(tester), closeTo(1, 0.001));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'paused cover starts small and previews from its displayed size',
    (tester) async {
      final service = _AudioService(PlayerState(false, ProcessingState.ready));
      final disabled = ValueNotifier(false);
      addTearDown(disabled.dispose);
      await _pumpPlayer(
        tester,
        service,
        size: const Size(390, 844),
        disableAnimations: disabled,
      );
      expect(_coverScale(tester), closeTo(0.9, 0.001));
      final cover = find.byKey(
        const ValueKey('player-cover-artwork-cover-scale-track'),
      );
      final sourceRect = tester.getRect(cover);
      await tester.tap(cover);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 501));
      await tester.pumpAndSettle();
      expect(find.byType(CoverPreviewDialog), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final flight = find.byKey(
        const ValueKey('player-cover-preview-flight-frame'),
      );
      expect(flight, findsOneWidget);
      expect(tester.getRect(flight).width, greaterThan(sourceRect.width));
      await tester.pumpAndSettle();
      expect(find.byType(CoverPreviewDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion immediately applies the target size', (
    tester,
  ) async {
    final service = _AudioService(PlayerState(true, ProcessingState.ready));
    final disabled = ValueNotifier(false);
    addTearDown(disabled.dispose);
    await _pumpPlayer(
      tester,
      service,
      size: const Size(390, 844),
      disableAnimations: disabled,
    );
    service.setState(false, ProcessingState.ready);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_coverScale(tester), greaterThan(0.9));
    disabled.value = true;
    await tester.pump();
    expect(_coverScale(tester), closeTo(0.9, 0.001));
    service.setState(true, ProcessingState.ready);
    await tester.pump();
    expect(_coverScale(tester), closeTo(1, 0.001));
    expect(tester.takeException(), isNull);
  });
}
