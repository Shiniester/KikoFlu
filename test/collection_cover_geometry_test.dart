import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/history_record.dart';
import 'package:kikoeru_flutter/src/models/playlist.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/work_card_display_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart'
    show LayoutType;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/collection_grid_layout.dart';
import 'package:kikoeru_flutter/src/widgets/age_rating_chip.dart';
import 'package:kikoeru_flutter/src/widgets/enhanced_work_card.dart';
import 'package:kikoeru_flutter/src/widgets/history_work_card.dart';
import 'package:kikoeru_flutter/src/widgets/playlist_card.dart';
import 'package:kikoeru_flutter/src/widgets/tag_chip.dart';
import 'package:kikoeru_flutter/src/widgets/va_chip.dart';
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
      'A long description that should expand naturally below the title without squeezing or overflowing the cover.',
  worksCount: 12,
);

Widget _testApp(
  Widget child, {
  double contentWidth = 180,
  Size windowSize = const Size(800, 700),
  TextScaler? textScaler,
}) => ProviderScope(
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(
          size: windowSize,
          disableAnimations: true,
          textScaler: textScaler ?? TextScaler.noScaling,
        ),
        child: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: contentWidth, child: child),
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
        await tester.pumpWidget(
          _testApp(
            buildCard(layout),
            contentWidth: layout == LayoutType.list ? 320 : 180,
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));

        final card = find.byKey(ValueKey('$cardName-$layout'));
        if (layout == LayoutType.list) {
          final coverClip = find
              .descendant(of: card, matching: find.byType(ClipRRect))
              .first;
          final coverSize = tester.getSize(coverClip);
          expect(coverSize.width / coverSize.height, 4 / 3);
          expect(
            tester.widget<ClipRRect>(coverClip).borderRadius,
            BorderRadius.circular(coverSize.width / 15),
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

  testWidgets(
    'list covers match four rendered title lines in every audio card',
    (tester) async {
      const title = 'One\nTwo\nThree\nFour';
      final work = _work.copyWith(title: title);
      const playlist = Playlist(
        id: 'four-lines',
        userName: 'Creator',
        privacy: 0,
        name: title,
      );
      final cards = <(String, Widget)>[
        (
          'work',
          EnhancedWorkCard(work: work, crossAxisCount: 1, isListLayout: true),
        ),
        (
          'history',
          HistoryWorkCard(
            record: HistoryRecord(work: work, lastPlayedTime: DateTime(2026)),
            layoutType: LayoutType.list,
          ),
        ),
        (
          'playlist',
          const PlaylistCard(playlist: playlist, layoutType: LayoutType.list),
        ),
      ];
      double? enhancedCoverHeight;

      for (final (name, card) in cards) {
        await tester.pumpWidget(
          _testApp(
            card,
            contentWidth: 320,
            windowSize: const Size(360, 800),
            textScaler: const TextScaler.linear(1.4),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));

        final titleFinder = find.text(title);
        final titleSize = tester.getSize(titleFinder);
        final coverFinder = find
            .descendant(
              of: find.byType(Card).first,
              matching: find.byType(ClipRRect),
            )
            .first;
        final coverSize = tester.getSize(coverFinder);
        expect(titleSize.height, closeTo(coverSize.height, 0.1), reason: name);
        expect(
          tester.widget<Text>(titleFinder).maxLines,
          collectionCardTitleMaxLines,
          reason: name,
        );
        expect(
          tester.widget<ClipRRect>(coverFinder).borderRadius,
          BorderRadius.circular(coverSize.width / 15),
          reason: name,
        );
        if (name == 'work') enhancedCoverHeight = coverSize.height;
        expect(tester.takeException(), isNull, reason: name);
      }

      await tester.pumpWidget(
        _testApp(
          EnhancedWorkCard(
            work: _work.copyWith(title: 'Short title'),
            crossAxisCount: 1,
            isListLayout: true,
          ),
          contentWidth: 320,
          windowSize: const Size(360, 800),
          textScaler: const TextScaler.linear(1.4),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final shortTitle = find.text('Short title');
      final shortCover = find.byType(ClipRRect).first;
      expect(
        tester.getSize(shortCover).height,
        closeTo(enhancedCoverHeight!, 0.1),
      );
      expect(
        tester.getSize(shortTitle).height,
        lessThan(tester.getSize(shortCover).height),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('audio list title and cover follow system text scaling', (
    tester,
  ) async {
    const title = 'One\nTwo\nThree\nFour';
    await tester.pumpWidget(
      _testApp(
        EnhancedWorkCard(
          work: _work.copyWith(title: title),
          crossAxisCount: 1,
          isListLayout: true,
        ),
        contentWidth: 320,
        windowSize: const Size(320, 800),
        textScaler: const TextScaler.linear(2.5),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final titleSize = tester.getSize(find.text(title));
    final coverSize = tester.getSize(find.byType(ClipRRect).first);
    expect(titleSize.height, closeTo(coverSize.height, 0.1));
    expect(coverSize.width / coverSize.height, closeTo(4 / 3, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long playlist title and description expand in list layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        const PlaylistCard(playlist: _playlist, layoutType: LayoutType.list),
        contentWidth: 320,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.textContaining('A deliberately long playlist title'),
      findsOneWidget,
    );
    final coverSize = tester.getSize(find.byType(ClipRRect).first);
    expect(coverSize.width / coverSize.height, 4 / 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('audio list tags use the compact big-cover spacing', (
    tester,
  ) async {
    final work = _work.copyWith(tags: [const Tag(id: 21, name: 'Healing')]);
    Future<(TagChip, Wrap)> render(bool list) async {
      await tester.pumpWidget(
        _testApp(
          EnhancedWorkCard(
            work: work,
            crossAxisCount: list ? 1 : 2,
            isListLayout: list,
          ),
          contentWidth: list ? 320 : 180,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final chipFinder = find.byType(TagChip).first;
      return (
        tester.widget<TagChip>(chipFinder),
        tester.widget<Wrap>(
          find.ancestor(of: chipFinder, matching: find.byType(Wrap)).first,
        ),
      );
    }

    final (gridChip, gridWrap) = await render(false);
    final (listChip, listWrap) = await render(true);
    expect(listChip.borderRadius, gridChip.borderRadius);
    expect(listChip.padding, gridChip.padding);
    expect(listChip.borderRadius, 6);
    expect(
      listChip.padding,
      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    );
    expect(listWrap.spacing, gridWrap.spacing);
    expect(listWrap.runSpacing, gridWrap.runSpacing);
    expect(listWrap.spacing, 3);
    expect(listWrap.runSpacing, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('audio card information order and spacing are shared by layout', (
    tester,
  ) async {
    final work = _work.copyWith(
      title: 'Audio card',
      name: 'Circle',
      vas: const [Va(id: 'va-1', name: 'Voice actor')],
      tags: const [Tag(id: 21, name: 'Healing')],
      duration: 3600,
      price: 700,
      rateAverage: 4.2,
      rateCount: 15,
      dlCount: 123,
    );
    final variants = [
      (
        name: 'compact',
        crossAxisCount: 3,
        isListLayout: false,
        width: 120.0,
        showsSales: true,
      ),
      (
        name: 'medium',
        crossAxisCount: 2,
        isListLayout: false,
        width: 180.0,
        showsSales: false,
      ),
      (
        name: 'list',
        crossAxisCount: 1,
        isListLayout: true,
        width: 320.0,
        showsSales: true,
      ),
    ];

    for (final variant in variants) {
      SharedPreferences.setMockInitialValues({
        'work_card_display_duration': true,
      });
      await tester.pumpWidget(
        _testApp(
          EnhancedWorkCard(
            work: work,
            crossAxisCount: variant.crossAxisCount,
            isListLayout: variant.isListLayout,
          ),
          contentWidth: variant.width,
          windowSize: const Size(390, 844),
        ),
      );
      await tester.pumpAndSettle();

      final durationRow = find
          .ancestor(
            of: find.byIcon(Icons.access_time),
            matching: find.byType(Row),
          )
          .first;
      final durationTop = tester.getRect(durationRow).top;
      final informationStart = variant.isListLayout
          ? tester.getRect(find.byType(ClipRRect).first).bottom
          : tester.getRect(find.text(work.title)).bottom;
      expect(
        durationTop - informationStart,
        collectionCardInfoSpacing,
        reason: variant.name,
      );

      final actor = find.text('Voice actor');
      final tag = find.text('Healing');
      final circle = find.text('Circle');
      final price = find.text(S.of(tester.element(actor)).priceInYen(700));
      final rating = find.text('4.2 (15)');
      final infoRects = [
        tester.getRect(durationRow),
        tester.getRect(actor),
        tester.getRect(tag),
        tester.getRect(circle),
        tester.getRect(price),
        tester.getRect(rating),
      ];
      for (var index = 0; index < infoRects.length - 1; index++) {
        expect(
          infoRects[index].top,
          lessThan(infoRects[index + 1].top),
          reason: variant.name,
        );
      }

      final actorChip = tester.widget<VaChip>(find.byType(VaChip).first);
      expect(actorChip.borderRadius, 6, reason: variant.name);
      expect(
        actorChip.padding,
        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        reason: variant.name,
      );
      final strings = S.of(tester.element(actor));
      expect(
        find.text(strings.soldCount('123')),
        variant.showsSales ? findsOneWidget : findsNothing,
        reason: variant.name,
      );
      expect(
        tester.getRect(find.byType(Card).first).bottom,
        greaterThan(tester.getRect(find.byType(ClipRRect).first).bottom),
        reason: variant.name,
      );
      expect(tester.takeException(), isNull, reason: variant.name);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'compact audio card shows enabled fields and removes hidden rows',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'work_card_display_duration': true,
      });
      final work = _work.copyWith(
        title: 'Audio card',
        name: 'Circle',
        vas: const [Va(id: 'va-1', name: 'Voice actor')],
        tags: const [Tag(id: 21, name: 'Healing')],
        duration: 3600,
        price: 700,
        rateAverage: 4.2,
        rateCount: 15,
        dlCount: 123,
      );
      await tester.pumpWidget(
        _testApp(
          EnhancedWorkCard(work: work, crossAxisCount: 3),
          contentWidth: 120,
          windowSize: const Size(390, 844),
          textScaler: const TextScaler.linear(2),
        ),
      );
      await tester.pumpAndSettle();

      final actor = find.text('Voice actor');
      final strings = S.of(tester.element(actor));
      final price = strings.priceInYen(700);
      final cardSizeWithAllFields = tester.getSize(find.byType(Card).first);
      final actorTopWithDuration = tester.getRect(actor).top;
      expect(find.text(strings.soldCount('123')), findsOneWidget);
      expect(find.text('Circle'), findsOneWidget);
      expect(find.text('4.2 (15)'), findsOneWidget);

      final notifier = ProviderScope.containerOf(
        tester.element(find.byType(EnhancedWorkCard)),
      ).read(workCardDisplayProvider.notifier);
      await notifier.toggleDuration();
      await tester.pump();
      expect(find.byIcon(Icons.access_time), findsNothing);
      expect(tester.getRect(actor).top, lessThan(actorTopWithDuration));

      await notifier.toggleSales();
      await notifier.toggleCircle();
      await notifier.togglePrice();
      await notifier.toggleRating();
      await tester.pump();
      expect(find.text(strings.soldCount('123')), findsNothing);
      expect(find.text('Circle'), findsNothing);
      expect(find.text(price), findsNothing);
      expect(find.text('4.2 (15)'), findsNothing);
      expect(
        tester.getSize(find.byType(Card).first).height,
        lessThan(cardSizeWithAllFields.height),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('audio work titles use four-line ellipsis in every layout', (
    tester,
  ) async {
    final variants = [
      (name: 'compact', crossAxisCount: 5, isListLayout: false, width: 180.0),
      (name: 'medium', crossAxisCount: 2, isListLayout: false, width: 180.0),
      (name: 'list', crossAxisCount: 1, isListLayout: true, width: 320.0),
    ];

    for (final variant in variants) {
      final work = _work.copyWith(
        title:
            'A deliberately long audio title that must stop after four lines and end with an ellipsis',
      );
      await tester.pumpWidget(
        _testApp(
          EnhancedWorkCard(
            work: work,
            crossAxisCount: variant.crossAxisCount,
            isListLayout: variant.isListLayout,
          ),
          contentWidth: variant.width,
          windowSize: const Size(360, 800),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final title = tester.widget<Text>(find.text(work.title));
      expect(title.maxLines, collectionCardTitleMaxLines, reason: variant.name);
      expect(title.overflow, TextOverflow.ellipsis, reason: variant.name);
      expect(tester.takeException(), isNull, reason: variant.name);
    }

    const shortTitle = 'Short title';
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _testApp(
        EnhancedWorkCard(
          work: _work.copyWith(title: shortTitle),
          crossAxisCount: 1,
          isListLayout: true,
        ),
        contentWidth: 320,
        windowSize: const Size(360, 800),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final shortTitleFinder = find.text(shortTitle);
    final shortTitleWidget = tester.widget<Text>(shortTitleFinder);
    expect(shortTitleWidget.maxLines, collectionCardTitleMaxLines);
    expect(
      tester.getSize(shortTitleFinder).height,
      lessThan(shortTitleWidget.style!.fontSize! * 1.3 * 4),
    );
  });

  testWidgets('audio cards hide user-added tags by default and can show them', (
    tester,
  ) async {
    const userAdded = Tag(id: 990001, name: 'Community label', voteStatus: 0);
    const catalogue = Tag(id: 990002, name: 'Catalogue label', voteStatus: 1);
    const unknownSource = Tag(id: 990003, name: 'Unclassified label');
    final work = _work.copyWith(tags: [userAdded, catalogue, unknownSource]);

    for (final isListLayout in [false, true]) {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        _testApp(
          EnhancedWorkCard(
            work: work,
            crossAxisCount: isListLayout ? 1 : 2,
            isListLayout: isListLayout,
          ),
          contentWidth: isListLayout ? 320 : 180,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Community label'), findsNothing);
      expect(find.text('Catalogue label'), findsOneWidget);
      expect(find.text('Unclassified label'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(EnhancedWorkCard)),
      );
      await container
          .read(workCardDisplayProvider.notifier)
          .toggleUserAddedTags();
      await tester.pump();

      expect(find.text('Community label'), findsOneWidget);
      expect(find.text('Catalogue label'), findsOneWidget);
      expect(find.text('Unclassified label'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('list release date appears once at the cover bottom right', (
    tester,
  ) async {
    const release = '2026-06-21';
    final work = _work.copyWith(release: release, hasSubtitle: true);
    await tester.pumpWidget(
      _testApp(
        EnhancedWorkCard(work: work, crossAxisCount: 1, isListLayout: true),
        contentWidth: 320,
        windowSize: const Size(360, 800),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final releaseFinder = find.text(release);
    expect(releaseFinder, findsOneWidget);
    final coverSize = tester.getSize(find.byType(ClipRRect).first);
    final infoScale = collectionCoverInfoScale(coverSize.width);
    final coverPosition = tester.widget<Positioned>(
      find.ancestor(of: releaseFinder, matching: find.byType(Positioned)).first,
    );
    expect(coverPosition.bottom, 2 * infoScale);
    expect(coverPosition.right, 2 * infoScale);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cover badge dimensions scale with the cover and fit narrow cards',
    (tester) async {
      final work = _work.copyWith(
        sourceId: 'RJ012345678901234567890123456789',
        release: '2026-06-21',
        age: 'R18',
        hasSubtitle: true,
      );
      await tester.pumpWidget(
        _testApp(
          EnhancedWorkCard(work: work, crossAxisCount: 1, isListLayout: true),
          contentWidth: 320,
          windowSize: const Size(360, 800),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(EnhancedWorkCard)),
      );
      final notifier = container.read(workCardDisplayProvider.notifier);
      await notifier.toggleAgeRating();
      await tester.pump();

      const scale = 0.7;
      final idFinder = find.text(work.displayId);
      expect(
        tester.widget<Text>(idFinder).style!.fontSize,
        closeTo(10 * scale, 0.01),
      );
      expect(
        tester.widget<Text>(find.text(work.release!)).style!.fontSize,
        closeTo(10 * scale, 0.01),
      );
      final idContainer = tester.widget<Container>(
        find.ancestor(of: idFinder, matching: find.byType(Container)).first,
      );
      expect(
        idContainer.padding,
        const EdgeInsets.symmetric(horizontal: 6 * scale, vertical: 2 * scale),
      );
      final ageRating = tester.widget<AgeRatingChip>(
        find.byType(AgeRatingChip),
      );
      expect(ageRating.fontSize, closeTo(10 * scale, 0.01));
      expect(
        ageRating.padding,
        const EdgeInsets.symmetric(horizontal: 6 * scale, vertical: 2 * scale),
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.closed_caption)).size,
        closeTo(14 * scale, 0.01),
      );
      expect(
        tester
            .widget<FittedBox>(
              find
                  .ancestor(of: idFinder, matching: find.byType(FittedBox))
                  .first,
            )
            .fit,
        BoxFit.scaleDown,
      );

      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        _testApp(
          EnhancedWorkCard(
            work: work.copyWith(
              title:
                  'A narrow card title that wraps and then truncates while keeping its metadata inside the cover',
            ),
            crossAxisCount: 5,
            isListLayout: false,
          ),
          contentWidth: 120,
          windowSize: const Size(320, 640),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final narrowContainer = ProviderScope.containerOf(
        tester.element(find.byType(EnhancedWorkCard)),
      );
      await narrowContainer
          .read(workCardDisplayProvider.notifier)
          .toggleAgeRating();
      await tester.pump();

      final compactCover = find.byType(ClipRRect).first;
      final compactScale = collectionCoverInfoScale(
        tester.getSize(compactCover).width,
      );
      final compactId = find.text(work.displayId);
      final compactIdPosition = tester.widget<Positioned>(
        find.ancestor(of: compactId, matching: find.byType(Positioned)).first,
      );
      expect(compactIdPosition.top, closeTo(6 * compactScale, 0.01));
      expect(compactIdPosition.left, closeTo(6 * compactScale, 0.01));
      final compactRelease = find.text(work.release!);
      final compactReleasePosition = tester.widget<Positioned>(
        find
            .ancestor(of: compactRelease, matching: find.byType(Positioned))
            .first,
      );
      expect(compactReleasePosition.bottom, closeTo(6 * compactScale, 0.01));
      expect(compactReleasePosition.right, closeTo(6 * compactScale, 0.01));
      expect(tester.takeException(), isNull);
    },
  );
}
