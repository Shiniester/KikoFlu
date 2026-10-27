import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/playlist.dart';
import 'package:kikoeru_flutter/src/models/user.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/playlist_detail_provider.dart';
import 'package:kikoeru_flutter/src/providers/playlist_display_provider.dart';
import 'package:kikoeru_flutter/src/screens/playlist_detail_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/work_cover_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _work = Work(id: 12345, title: 'One\nTwo\nThree\nFour');

class _UnusedApi extends Fake implements KikoeruApiService {}

class _LoadedPlaylist extends PlaylistDetailNotifier {
  _LoadedPlaylist({bool owned = false}) : super(_UnusedApi(), 'geometry', 40) {
    state = PlaylistDetailState(
      works: const [_work],
      totalCount: 1,
      metadata: owned
          ? const Playlist(
              id: 'geometry',
              userName: 'Owner',
              privacy: 0,
              name: 'Geometry',
            )
          : null,
    );
  }

  @override
  Future<void> load({bool refresh = false}) async {}
}

class _OwnerAuth extends StateNotifier<AuthState> implements AuthNotifier {
  _OwnerAuth()
    : super(
        const AuthState(currentUser: User(name: 'Owner'), isLoggedIn: true),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('playlist detail shares card geometry in both layouts', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final size in [const Size(320, 800), const Size(1280, 800)]) {
      tester.view.physicalSize = size;
      for (final layout in PlaylistLayoutType.values) {
        SharedPreferences.setMockInitialValues({
          PlaylistDisplayNotifier.preferenceKey: layout.value,
        });
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        final container = ProviderContainer(
          overrides: [
            playlistDetailProvider(
              'geometry',
            ).overrideWith((ref) => _LoadedPlaylist()),
          ],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              locale: Locale('en'),
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: PlaylistDetailScreen(playlistId: 'geometry'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final title = find.text(_work.title);
        expect(tester.widget<Text>(title).maxLines, 4);
        final card = find
            .ancestor(of: title, matching: find.byType(InkWell))
            .first;
        expect(tester.getRect(card).left, size.width > size.height ? 24 : 8);
        if (layout == PlaylistLayoutType.list) {
          final coverSize = tester.getSize(find.byType(WorkCoverImage));
          expect(coverSize.height, closeTo(tester.getSize(title).height, 0.1));
          expect(coverSize.width / coverSize.height, 4 / 3);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      }
    }
  });

  testWidgets('owned playlist actions fit large-text list cards after resize', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final s = await S.delegate.load(const Locale('en'));

    for (final size in [const Size(320, 800), const Size(1280, 800)]) {
      tester.view.physicalSize = size;
      SharedPreferences.setMockInitialValues({
        PlaylistDisplayNotifier.preferenceKey: PlaylistLayoutType.list.value,
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith((ref) => _OwnerAuth()),
          playlistDetailProvider(
            'geometry',
          ).overrideWith((ref) => _LoadedPlaylist(owned: true)),
        ],
      );
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
              ).copyWith(textScaler: const TextScaler.linear(2.5)),
              child: child!,
            ),
            home: const PlaylistDetailScreen(playlistId: 'geometry'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final title = find.text(_work.title);
      await tester.ensureVisible(title);
      await tester.pumpAndSettle();
      final card = find
          .ancestor(of: title, matching: find.byType(InkWell))
          .first;
      final bounds = tester.getRect(card);
      final cover = tester.getRect(
        find.descendant(of: card, matching: find.byType(WorkCoverImage)),
      );
      final remove = find.byTooltip(s.removeFromPlaylist);
      for (final rect in [
        cover,
        tester.getRect(title),
        tester.getRect(remove),
      ]) {
        expect(rect.left, greaterThanOrEqualTo(bounds.left));
        expect(rect.right, lessThanOrEqualTo(bounds.right));
        expect(rect.top, greaterThanOrEqualTo(bounds.top));
        expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
      }
      expect(cover.height, closeTo(tester.getSize(title).height, 0.1));
      expect(cover.width / cover.height, closeTo(4 / 3, 0.001));
      expect(tester.takeException(), isNull, reason: '$size');

      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text(s.cancel));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    }
  });
}
