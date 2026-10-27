import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/work_card_display_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/screens/work_card_display_settings_screen.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/works_grid_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _work = Work(
  id: 1,
  title: 'A test work with a reasonably long title',
  name: 'Circle',
);

Widget _testApp(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      home: child,
    ),
  );
}

Future<void> _pumpAsyncPreferenceLoad(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets(
    'large card setting reduces grid column count without changing default',
    (tester) async {
      await tester.pumpWidget(
        _testApp(
          const MediaQuery(
            data: MediaQueryData(size: Size(400, 800)),
            child: WorksGridView(
              works: [_work],
              layoutType: LayoutType.bigGrid,
            ),
          ),
        ),
      );
      await _pumpAsyncPreferenceLoad(tester);

      expect(
        tester
            .widget<SliverMasonryGrid>(find.byType(SliverMasonryGrid))
            .gridDelegate,
        isA<SliverSimpleGridDelegateWithFixedCrossAxisCount>().having(
          (delegate) => delegate.crossAxisCount,
          'crossAxisCount',
          2,
        ),
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byType(WorksGridView)),
      );
      await container
          .read(workCardDisplayProvider.notifier)
          .updateCardSize(WorkCardSize.large);
      await tester.pump();

      expect(
        tester
            .widget<SliverMasonryGrid>(find.byType(SliverMasonryGrid))
            .gridDelegate,
        isA<SliverSimpleGridDelegateWithFixedCrossAxisCount>().having(
          (delegate) => delegate.crossAxisCount,
          'crossAxisCount',
          1,
        ),
      );
    },
  );

  testWidgets('small grid keeps a distinct layout with extra large cards', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        const MediaQuery(
          data: MediaQueryData(size: Size(400, 800)),
          child: WorksGridView(
            works: [_work],
            layoutType: LayoutType.smallGrid,
          ),
        ),
      ),
    );
    await _pumpAsyncPreferenceLoad(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(WorksGridView)),
    );
    await container
        .read(workCardDisplayProvider.notifier)
        .updateCardSize(WorkCardSize.extraLarge);
    await tester.pump();

    expect(
      tester
          .widget<SliverMasonryGrid>(find.byType(SliverMasonryGrid))
          .gridDelegate,
      isA<SliverSimpleGridDelegateWithFixedCrossAxisCount>().having(
        (delegate) => delegate.crossAxisCount,
        'crossAxisCount',
        2,
      ),
    );
  });

  testWidgets('uses the actual constrained width for narrow grid windows', (
    tester,
  ) async {
    final originalPhysicalSize = tester.view.physicalSize;
    final originalDevicePixelRatio = tester.view.devicePixelRatio;
    addTearDown(() {
      tester.view.physicalSize = originalPhysicalSize;
      tester.view.devicePixelRatio = originalDevicePixelRatio;
    });
    tester.view.physicalSize = const Size(300, 600);
    tester.view.devicePixelRatio = 1;

    await tester.pumpWidget(
      _testApp(
        const MediaQuery(
          data: MediaQueryData(size: Size(800, 600)),
          child: WorksGridView(works: [_work], layoutType: LayoutType.bigGrid),
        ),
      ),
    );
    await _pumpAsyncPreferenceLoad(tester);

    expect(
      tester
          .widget<SliverMasonryGrid>(find.byType(SliverMasonryGrid))
          .gridDelegate,
      isA<SliverSimpleGridDelegateWithFixedCrossAxisCount>().having(
        (delegate) => delegate.crossAxisCount,
        'crossAxisCount',
        1,
      ),
    );
    expect(find.byType(AspectRatio), findsOneWidget);
    expect(
      tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
      4 / 3,
    );
  });

  testWidgets('collection cards align to responsive page padding', (
    tester,
  ) async {
    final originalPhysicalSize = tester.view.physicalSize;
    final originalDevicePixelRatio = tester.view.devicePixelRatio;
    addTearDown(() {
      tester.view.physicalSize = originalPhysicalSize;
      tester.view.devicePixelRatio = originalDevicePixelRatio;
    });

    final works = List.generate(
      40,
      (index) => Work(id: index + 1, title: 'Collection work $index'),
    );

    for (final size in [const Size(320, 800), const Size(1280, 800)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final expectedPadding = size.width > size.height ? 24.0 : 8.0;

      for (final layoutType in LayoutType.values) {
        await tester.pumpWidget(
          _testApp(
            Scaffold(
              body: WorksGridView(
                works: works,
                layoutType: layoutType,
                padding: const EdgeInsets.all(16),
              ),
            ),
          ),
        );
        await _pumpAsyncPreferenceLoad(tester);

        final cards = find.byType(Card).hitTestable();
        expect(cards, findsWidgets);
        final rects = [
          for (var index = 0; index < cards.evaluate().length; index++)
            tester.getRect(cards.at(index)),
        ];
        final left = rects
            .map((rect) => rect.left)
            .reduce((first, second) => first < second ? first : second);
        final right = rects
            .map((rect) => rect.right)
            .reduce((first, second) => first > second ? first : second);

        expect(left, expectedPadding, reason: '$layoutType at $size');
        expect(
          right,
          size.width - expectedPadding,
          reason: '$layoutType at $size',
        );
      }
    }
  });

  testWidgets('settings screen updates card text size segmented control', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(const WorkCardDisplaySettingsScreen()));
    await _pumpAsyncPreferenceLoad(tester);

    await tester.tap(find.text('XL').last);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(WorkCardDisplaySettingsScreen)),
    );

    expect(
      container.read(workCardDisplayProvider).fontScale,
      WorkCardFontScale.extraLarge,
    );
  });

  testWidgets('settings screen toggles user-added tags on work cards', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(const WorkCardDisplaySettingsScreen()));
    await _pumpAsyncPreferenceLoad(tester);

    final setting = find.widgetWithText(SwitchListTile, 'User-added Tags');
    expect(tester.widget<SwitchListTile>(setting).value, isFalse);

    await tester.ensureVisible(setting);
    await tester.pumpAndSettle();
    await tester.tap(setting);
    await tester.pump();

    expect(tester.widget<SwitchListTile>(setting).value, isTrue);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(WorkCardDisplaySettingsScreen)),
    );
    expect(container.read(workCardDisplayProvider).showUserAddedTags, isTrue);
  });
}
