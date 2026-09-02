import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_tap_playlist_mode.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
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
    expect(find.text('Replace Playlist'), findsOneWidget);
    expect(find.text('Play Next'), findsOneWidget);
    expect(find.text('Add to Playlist'), findsOneWidget);

    await tester.tap(
      find.ancestor(
        of: find.text('Add to Playlist'),
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
    expect(find.byIcon(Icons.queue_play_next), findsOneWidget);
    expect(
      container.read(audioTapPlaylistModeProvider),
      AudioTapPlaylistMode.playNext,
    );
  });

  testWidgets('queue mode expansion stays above the existing mode pill', (
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

    await tester.tap(find.byKey(const ValueKey('playlist-mode-pill')));
    await tester.pumpAndSettle();
    final optionsRect = tester.getRect(
      find.byKey(const ValueKey('playlist-mode-expanded-options')),
    );
    final pillRect = tester.getRect(
      find.byKey(const ValueKey('playlist-mode-pill')),
    );
    expect(optionsRect.bottom, lessThanOrEqualTo(pillRect.top));
    expect(optionsRect.width, closeTo(pillRect.width, 0.01));
    final addTop = tester.getTopLeft(
      find.byKey(const ValueKey('playlist-mode-option-addToQueue')),
    );
    final nextTop = tester.getTopLeft(
      find.byKey(const ValueKey('playlist-mode-option-playNext')),
    );
    final replaceTop = tester.getTopLeft(
      find.byKey(const ValueKey('playlist-mode-option-replaceQueue')),
    );
    expect(addTop.dy, lessThan(nextTop.dy));
    expect(nextTop.dy, lessThan(replaceTop.dy));

    await tester.tap(
      find.byKey(const ValueKey('playlist-mode-option-playNext')),
    );
    await tester.pumpAndSettle();
    expect(
      container.read(audioTapPlaylistModeProvider),
      AudioTapPlaylistMode.playNext,
    );
    expect(
      find.byKey(const ValueKey('playlist-mode-expanded-options')),
      findsNothing,
    );
  });
}
