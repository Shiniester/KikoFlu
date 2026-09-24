import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/history_record.dart';
import 'package:kikoeru_flutter/src/models/playlist.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart'
    show LayoutType;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/enhanced_work_card.dart';
import 'package:kikoeru_flutter/src/widgets/history_work_card.dart';
import 'package:kikoeru_flutter/src/widgets/playlist_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _work = Work(
  id: 12345,
  title:
      'A deliberately long work title that wraps over multiple lines in a list card',
);

const _playlist = Playlist(
  id: 'playlist-1',
  userName: 'Creator',
  privacy: 0,
  name:
      'A deliberately long playlist title that wraps over multiple lines in the collection card',
  description:
      'A long description that should expand naturally below the title without squeezing or overflowing the fixed-size cover.',
  worksCount: 12,
);

Widget _testApp(Widget child) => ProviderScope(
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: Scaffold(
      body: MediaQuery(
        data: const MediaQueryData(
          size: Size(800, 700),
          disableAnimations: true,
        ),
        child: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 180, child: child),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets('collection cards share cover size and radius in every layout', (
    tester,
  ) async {
    final cards = <(String, Widget Function(LayoutType))>[
      (
        'work',
        (layout) => EnhancedWorkCard(
          key: ValueKey('work-$layout'),
          work: _work,
          crossAxisCount: layout == LayoutType.list ? 1 : 2,
          isListLayout: layout == LayoutType.list,
        ),
      ),
      (
        'history',
        (layout) => HistoryWorkCard(
          key: ValueKey('history-$layout'),
          record: HistoryRecord(work: _work, lastPlayedTime: DateTime(2026)),
          layoutType: layout,
        ),
      ),
      (
        'playlist',
        (layout) => PlaylistCard(
          key: ValueKey('playlist-$layout'),
          playlist: _playlist,
          layoutType: layout,
        ),
      ),
    ];

    for (final layout in LayoutType.values) {
      for (final (cardName, buildCard) in cards) {
        await tester.pumpWidget(_testApp(buildCard(layout)));
        await tester.pump(const Duration(milliseconds: 300));

        final card = find.byKey(ValueKey('$cardName-$layout'));
        if (layout == LayoutType.list) {
          final coverClip = find
              .descendant(of: card, matching: find.byType(ClipRRect))
              .first;
          expect(tester.getSize(coverClip), const Size(80, 60));
          expect(
            tester.widget<ClipRRect>(coverClip).borderRadius,
            BorderRadius.circular(80 / 15),
          );
        } else {
          final aspectRatio = find
              .descendant(of: card, matching: find.byType(AspectRatio))
              .first;
          expect(tester.getSize(aspectRatio).width, 180);
          expect(tester.getSize(aspectRatio).height, 135);
          final cardWidget = tester.widget<Card>(
            find.descendant(of: card, matching: find.byType(Card)).first,
          );
          expect(
            (cardWidget.shape! as RoundedRectangleBorder).borderRadius,
            BorderRadius.circular(12),
          );
        }

        expect(tester.takeException(), isNull, reason: '$cardName in $layout');
      }
    }
  });

  testWidgets('long playlist title and description expand in list layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        const PlaylistCard(playlist: _playlist, layoutType: LayoutType.list),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.textContaining('A deliberately long playlist title'),
      findsOneWidget,
    );
    expect(tester.getSize(find.byType(ClipRRect).first), const Size(80, 60));
    expect(tester.takeException(), isNull);
  });
}
