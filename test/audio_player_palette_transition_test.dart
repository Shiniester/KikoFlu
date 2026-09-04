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
import 'package:kikoeru_flutter/src/widgets/player/player_visual_palette.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _descriptorProvider = StateProvider<ArtworkDescriptor?>((ref) => null);

const _firstTrack = AudioTrack(
  id: 'palette-first',
  title: 'First',
  url: 'https://example.invalid/first.mp3',
);
const _secondTrack = AudioTrack(
  id: 'palette-second',
  title: 'Second',
  url: 'https://example.invalid/second.mp3',
);
const _thirdTrack = AudioTrack(
  id: 'palette-third',
  title: 'Third',
  url: 'https://example.invalid/third.mp3',
);

const _firstDescriptor = ArtworkDescriptor(
  trackIdentity: 'palette-first',
  source: 'https://example.invalid/first.jpg',
  cacheKey: 'palette-first',
);
const _secondDescriptor = ArtworkDescriptor(
  trackIdentity: 'palette-second',
  source: 'https://example.invalid/second.jpg',
  cacheKey: 'palette-second',
);
const _thirdDescriptor = ArtworkDescriptor(
  trackIdentity: 'palette-third',
  source: 'https://example.invalid/third.jpg',
  cacheKey: 'palette-third',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true});
  });

  testWidgets(
    'player retains the previous palette and keeps rapid transitions opaque',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final tracks = StreamController<AudioTrack?>();
      final loader = _ControllableArtworkSeedLoader();
      final appScheme = ColorScheme.fromSeed(seedColor: Colors.teal);
      final container = ProviderContainer(
        overrides: [
          currentTrackProvider.overrideWith((ref) => tracks.stream),
          themeArtworkDescriptorProvider.overrideWith(
            (ref) => ref.watch(_descriptorProvider),
          ),
          artworkSeedLoaderProvider.overrideWithValue(loader),
          isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
          positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
          durationProvider.overrideWith(
            (ref) => Stream.value(const Duration(minutes: 4)),
          ),
          playerStateProvider.overrideWith(
            (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
          ),
          queueProvider.overrideWith(
            (ref) =>
                Stream.value(const [_firstTrack, _secondTrack, _thirdTrack]),
          ),
          lyricAutoLoaderProvider.overrideWith((ref) {}),
        ],
      );
      addTearDown(tracks.close);
      addTearDown(container.dispose);

      Widget buildPlayer(ColorScheme colorScheme) {
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true, colorScheme: colorScheme),
            themeAnimationDuration: const Duration(milliseconds: 300),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: const AudioPlayerScreen(),
          ),
        );
      }

      container.read(_descriptorProvider.notifier).state = _firstDescriptor;
      tracks.add(_firstTrack);
      await tester.pumpWidget(buildPlayer(appScheme));
      await _pumpMicrotasks(tester);
      expect(loader.hasPending('palette-first'), isTrue);
      loader.complete('palette-first', Colors.indigo);
      await _pumpMicrotasks(tester);
      await tester.pump(const Duration(milliseconds: 300));

      final firstPalette = PlayerVisualPalette.fromDominant(
        Colors.indigo,
        brightness: Brightness.light,
        accent: appScheme.primary,
        onAccent: appScheme.onPrimary,
      );
      expect(
        _backgroundTargetColors(tester),
        orderedEquals([
          firstPalette.backgroundStart,
          firstPalette.backgroundMiddle,
          firstPalette.backgroundEnd,
        ]),
      );

      container.read(_descriptorProvider.notifier).state = _secondDescriptor;
      tracks.add(_secondTrack);
      await _pumpMicrotasks(tester);
      expect(loader.hasPending('palette-second'), isTrue);
      expect(container.read(artworkThemeSeedProvider).isLoading, isTrue);
      expect(container.read(artworkThemeSeedProvider).seed, Colors.indigo);
      expect(
        _backgroundTargetColors(tester),
        orderedEquals([
          firstPalette.backgroundStart,
          firstPalette.backgroundMiddle,
          firstPalette.backgroundEnd,
        ]),
      );

      loader.complete('palette-second', Colors.pink);
      await _pumpMicrotasks(tester);
      await tester.pump(const Duration(milliseconds: 80));

      final nextAppScheme = ColorScheme.fromSeed(seedColor: Colors.amber);
      await tester.pumpWidget(buildPlayer(nextAppScheme));
      await tester.pump(const Duration(milliseconds: 16));

      container.read(_descriptorProvider.notifier).state = _thirdDescriptor;
      tracks.add(_thirdTrack);
      await _pumpMicrotasks(tester);
      expect(loader.hasPending('palette-third'), isTrue);
      loader.complete('palette-third', Colors.orange);
      await _pumpMicrotasks(tester);

      final background = find.byKey(
        const ValueKey('player-palette-background'),
      );
      expect(background, findsOneWidget);
      expect(
        find.descendant(
          of: background,
          matching: find.byType(AnimatedSwitcher),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: background, matching: find.byType(FadeTransition)),
        findsNothing,
      );
      expect(
        _backgroundAnimatedContainers(tester).map((widget) => widget.duration),
        everyElement(const Duration(milliseconds: 280)),
      );

      for (final elapsed in const [16, 32, 64, 96, 160, 280]) {
        await tester.pump(Duration(milliseconds: elapsed));
        final paintedColors = _paintedBackgroundColors(tester);
        expect(
          paintedColors.every((color) => color.a == 1),
          isTrue,
          reason: 'The animated gradient must stay opaque at every frame.',
        );
        expect(
          paintedColors.map(_luma).reduce((a, b) => a + b) /
              paintedColors.length,
          greaterThan(60),
          reason: 'The transition must not collapse toward a black backdrop.',
        );
      }

      final thirdPalette = PlayerVisualPalette.fromDominant(
        Colors.orange,
        brightness: Brightness.light,
        accent: nextAppScheme.primary,
        onAccent: nextAppScheme.onPrimary,
      );
      expect(
        _backgroundTargetColors(tester),
        orderedEquals([
          thirdPalette.backgroundStart,
          thirdPalette.backgroundMiddle,
          thirdPalette.backgroundEnd,
        ]),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('player background switches immediately with reduced motion', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentTrackProvider.overrideWith((ref) => Stream.value(_firstTrack)),
          isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
          positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
          durationProvider.overrideWith(
            (ref) => Stream.value(const Duration(minutes: 4)),
          ),
          playerStateProvider.overrideWith(
            (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
          ),
          queueProvider.overrideWith(
            (ref) => Stream.value(const [_firstTrack]),
          ),
          lyricAutoLoaderProvider.overrideWith((ref) {}),
        ],
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: AudioPlayerScreen(),
          ),
        ),
      ),
    );
    await _pumpMicrotasks(tester);

    expect(
      _backgroundAnimatedContainers(tester).map((widget) => widget.duration),
      everyElement(Duration.zero),
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpMicrotasks(WidgetTester tester) async {
  for (var index = 0; index < 5; index++) {
    await tester.pump();
  }
}

List<Color> _backgroundTargetColors(WidgetTester tester) {
  for (final container in _backgroundAnimatedContainers(tester)) {
    final decoration = container.decoration;
    if (decoration is BoxDecoration && decoration.gradient is LinearGradient) {
      return (decoration.gradient! as LinearGradient).colors;
    }
  }
  fail('Player background does not contain an animated linear gradient');
}

Iterable<AnimatedContainer> _backgroundAnimatedContainers(WidgetTester tester) {
  final background = find.byKey(const ValueKey('player-palette-background'));
  return tester.widgetList<AnimatedContainer>(
    find.descendant(of: background, matching: find.byType(AnimatedContainer)),
  );
}

List<Color> _paintedBackgroundColors(WidgetTester tester) {
  final background = find.byKey(const ValueKey('player-palette-background'));
  final decoratedBoxes = tester.widgetList<DecoratedBox>(
    find.descendant(of: background, matching: find.byType(DecoratedBox)),
  );
  for (final box in decoratedBoxes) {
    final decoration = box.decoration;
    if (decoration is BoxDecoration && decoration.gradient is LinearGradient) {
      return (decoration.gradient! as LinearGradient).colors;
    }
  }
  fail('Player background does not paint a linear gradient');
}

double _luma(Color color) =>
    0.2126 * color.r * 255 + 0.7152 * color.g * 255 + 0.0722 * color.b * 255;

class _ControllableArtworkSeedLoader implements ArtworkSeedLoader {
  final Map<String, Completer<Color>> _pending = {};

  @override
  Future<Color> load(ArtworkSeedRequest request) {
    return (_pending[request.cacheKey] ??= Completer<Color>()).future;
  }

  bool hasPending(String key) => _pending[key]?.isCompleted == false;

  void complete(String key, Color color) => _pending[key]!.complete(color);
}
