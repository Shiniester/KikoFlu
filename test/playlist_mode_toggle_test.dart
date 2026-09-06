import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_tap_playlist_mode.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
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
    expect(tester.widget<Icon>(find.byIcon(Icons.playlist_add)).size, 18);
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
    expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
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
    expect(find.byIcon(Icons.playlist_play), findsOneWidget);

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
