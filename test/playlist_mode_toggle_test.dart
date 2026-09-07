import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_tap_playlist_mode.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_glass_surface.dart';
import 'package:kikoeru_flutter/src/widgets/player/playlist_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('playlist mode menu selects and persists all modes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      AudioTapPlaylistModeNotifier.preferenceKey:
          AudioTapPlaylistMode.replaceQueue.name,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(body: PlaylistModeToggle()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.playlist_play), findsOneWidget);
    expect(find.byType(PopupMenuButton<AudioTapPlaylistMode>), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<AudioTapPlaylistMode>));
    await tester.pumpAndSettle();
    expect(find.text('Replace Playback Queue'), findsOneWidget);
    expect(find.text('Play Next'), findsOneWidget);
    expect(find.text('Add to Playback Queue'), findsOneWidget);

    await tester.tap(
      find.ancestor(
        of: find.text('Add to Playback Queue'),
        matching: find.byType(CheckedPopupMenuItem<AudioTapPlaylistMode>),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.playlist_add), findsOneWidget);
    expect(
      container.read(audioTapPlaylistModeProvider),
      AudioTapPlaylistMode.addToQueue,
    );

    await tester.tap(find.byType(PopupMenuButton<AudioTapPlaylistMode>));
    await tester.pumpAndSettle();
    await tester.tap(
      find.ancestor(
        of: find.text('Play Next'),
        matching: find.byType(CheckedPopupMenuItem<AudioTapPlaylistMode>),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
    expect(
      container.read(audioTapPlaylistModeProvider),
      AudioTapPlaylistMode.playNext,
    );
  });

  testWidgets('queue mode pill cycles modes without opening a menu', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: EdgeInsets.all(16),
                child: PlaylistModePill(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final pillFinder = find.byKey(const ValueKey('playlist-mode-pill'));
    final pill = tester.widget<PlayerGlassSurface>(pillFinder);
    expect(
      pill.padding,
      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    );
    expect(tester.getSize(pillFinder).height, lessThan(44));
    expect(
      tester
          .getSize(find.byKey(const ValueKey('playlist-mode-pill-tap-target')))
          .height,
      48,
    );
    expect(find.text('Add to Playback Queue'), findsOneWidget);
    expect(
      find.descendant(of: pillFinder, matching: find.byType(Icon)),
      findsNothing,
    );
    expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
    final modeInk = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const ValueKey('playlist-mode-pill-tap-target')),
        matching: find.byType(InkWell),
      ),
    );
    expect(
      modeInk.overlayColor?.resolve({WidgetState.pressed}),
      Colors.transparent,
    );
    expect(modeInk.splashFactory, same(NoSplash.splashFactory));

    final tapTargetFinder = find.byKey(
      const ValueKey('playlist-mode-pill-tap-target'),
    );
    await tester.tap(tapTargetFinder);
    await tester.pumpAndSettle();
    expect(
      container.read(audioTapPlaylistModeProvider),
      AudioTapPlaylistMode.playNext,
    );
    expect(find.text('Play Next'), findsOneWidget);
    expect(
      find.descendant(of: pillFinder, matching: find.byType(Icon)),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('playlist-mode-expanded-options')),
      findsNothing,
    );

    await tester.tap(tapTargetFinder);
    await tester.pumpAndSettle();
    expect(
      container.read(audioTapPlaylistModeProvider),
      AudioTapPlaylistMode.replaceQueue,
    );
    expect(find.text('Replace Playback Queue'), findsOneWidget);
    expect(
      find.descendant(of: pillFinder, matching: find.byType(Icon)),
      findsNothing,
    );

    await tester.tap(tapTargetFinder);
    await tester.pumpAndSettle();
    expect(
      container.read(audioTapPlaylistModeProvider),
      AudioTapPlaylistMode.addToQueue,
    );
    expect(find.text('Add to Playback Queue'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(AudioTapPlaylistModeNotifier.preferenceKey),
      AudioTapPlaylistMode.addToQueue.name,
    );
  });

  testWidgets(
    'empty queue shows mirrored text mode controls and cycles repeat mode',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
          queueProvider.overrideWith((ref) => Stream.value(const [])),
          audioPlayerControllerProvider.overrideWith(
            (ref) => _FakeAudioPlayerController(ref),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const Scaffold(
              body: SizedBox(
                width: 320,
                height: 480,
                child: PlayerQueueSurface(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final repeatTarget = find.byKey(
        const ValueKey('repeat-mode-pill-tap-target'),
      );
      final addTarget = find.byKey(
        const ValueKey('playlist-mode-pill-tap-target'),
      );
      expect(repeatTarget, findsOneWidget);
      expect(addTarget, findsOneWidget);
      expect(find.text('Sequential Queue Playback'), findsOneWidget);
      expect(find.text('Add to Playback Queue'), findsOneWidget);
      expect(tester.getRect(repeatTarget).left, closeTo(8, 0.01));
      expect(tester.getRect(addTarget).right, closeTo(312, 0.01));
      expect(tester.getRect(repeatTarget).center.dx, lessThan(160));
      expect(tester.getRect(addTarget).center.dx, greaterThan(160));
      for (final target in [repeatTarget, addTarget]) {
        expect(
          find.descendant(of: target, matching: find.byType(Icon)),
          findsNothing,
        );
        final text = tester.widget<Text>(
          find.descendant(of: target, matching: find.byType(Text)),
        );
        expect(text.maxLines, 1);
        expect(text.overflow, TextOverflow.ellipsis);
      }
      final repeatSemantics = tester.widget<Semantics>(
        find.ancestor(of: repeatTarget, matching: find.byType(Semantics)).first,
      );
      final addSemantics = tester.widget<Semantics>(
        find.ancestor(of: addTarget, matching: find.byType(Semantics)).first,
      );
      expect(
        repeatSemantics.properties.label,
        'Repeat Mode: Sequential Queue Playback',
      );
      expect(
        addSemantics.properties.label,
        'Audio Add Mode: Add to Playback Queue',
      );

      await tester.tap(repeatTarget);
      await tester.pump();
      expect(
        container.read(audioPlayerControllerProvider).repeatMode,
        LoopMode.one,
      );
      expect(find.text('Single Track Repeat'), findsOneWidget);

      await tester.tap(repeatTarget);
      await tester.pump();
      expect(
        container.read(audioPlayerControllerProvider).repeatMode,
        LoopMode.all,
      );
      expect(find.text('Queue Repeat'), findsOneWidget);

      await tester.tap(repeatTarget);
      await tester.pump();
      expect(
        container.read(audioPlayerControllerProvider).repeatMode,
        LoopMode.off,
      );
      expect(find.text('Sequential Queue Playback'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('audio add mode defaults invalid preferences to add-to-queue', () async {
    SharedPreferences.setMockInitialValues({
      AudioTapPlaylistModeNotifier.preferenceKey: 'invalid',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final mode = await container
        .read(audioTapPlaylistModeProvider.notifier)
        .getMode();

    expect(mode, AudioTapPlaylistMode.addToQueue);
  });
}

class _FakeAudioPlayerController extends AudioPlayerController {
  _FakeAudioPlayerController(Ref ref) : super(AudioPlayerService.instance, ref);

  @override
  Future<void> setRepeatMode(LoopMode mode) async {
    state = state.copyWith(repeatMode: mode);
  }
}
