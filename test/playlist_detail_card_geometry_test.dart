import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/playlist_detail_provider.dart';
import 'package:kikoeru_flutter/src/providers/playlist_display_provider.dart';
import 'package:kikoeru_flutter/src/screens/playlist_detail_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/collection_grid_layout.dart';
import 'package:kikoeru_flutter/src/widgets/work_cover_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _work = Work(
  id: 12345,
  title:
      'A long playlist work title '
      'that wraps across several lines without expanding beyond four lines',
);

class _UnusedApi extends Fake implements KikoeruApiService {}

class _LoadedPlaylist extends PlaylistDetailNotifier {
  _LoadedPlaylist() : super(_UnusedApi(), 'geometry', 40) {
    state = const PlaylistDetailState(works: [_work], totalCount: 1);
  }

  @override
  Future<void> load({bool refresh = false}) async {}
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
          expect(
            tester.getSize(find.byType(WorkCoverImage)),
            collectionListCoverSize,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      }
    }
  });
}
