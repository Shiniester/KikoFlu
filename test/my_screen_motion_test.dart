import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/providers/history_provider.dart';
import 'package:kikoeru_flutter/src/providers/my_reviews_provider.dart';
import 'package:kikoeru_flutter/src/screens/my_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Reviews extends MyReviewsNotifier {
  _Reviews(Ref ref) : super(KikoeruApiService(), ref);

  @override
  Future<void> load({
    bool refresh = false,
    int? targetPage,
    bool append = false,
    bool supersede = false,
  }) async {}
}

class _History extends HistoryNotifier {
  _History(super.ref);

  @override
  Future<void> load({
    bool refresh = false,
    bool force = false,
    int? targetPage,
  }) async {}
}

Future<void> _pumpMyScreen(
  WidgetTester tester,
  ValueNotifier<bool> reduced,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        myReviewsProvider.overrideWith((ref) => _Reviews(ref)),
        historyProvider.overrideWith((ref) => _History(ref)),
        downloadSummaryProvider.overrideWith(
          (ref) => Stream.value(const DownloadTaskSummary.empty()),
        ),
        downloadTaskIdsProvider.overrideWith((ref) => Stream.value(<String>[])),
      ],
      child: MaterialApp(
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: ValueListenableBuilder<bool>(
          valueListenable: reduced,
          child: const MyScreen(),
          builder: (context, value, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: value),
            child: child!,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

PageController _pages(WidgetTester tester) => tester
    .widget<PageView>(
      find.descendant(
        of: find.byType(TabBarView),
        matching: find.byType(PageView),
      ),
    )
    .controller!;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'my_tabs_show_playlists': false,
      'my_tabs_show_subtitle_library': false,
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets('reduced motion switches My tabs immediately', (tester) async {
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpMyScreen(tester, reduced);
    expect(
      tester.widget<TabBar>(find.byType(TabBar)).controller!.animationDuration,
      Duration.zero,
    );
    for (final index in [1, 2, 0]) {
      await tester.tap(find.byType(Tab).at(index));
      await tester.pump();
      expect(_pages(tester).page, index.toDouble());
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reduced motion finishes My tab travel without remounting pages',
    (tester) async {
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await _pumpMyScreen(tester, reduced);
      final pageView = tester.element(find.byType(TabBarView));
      await tester.tap(find.byType(Tab).at(2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(_pages(tester).page, lessThan(2));
      reduced.value = true;
      await tester.pump();
      expect(_pages(tester).page, 2);
      await tester.pumpAndSettle();

      reduced.value = false;
      await tester.pump();
      expect(tester.element(find.byType(TabBarView)), same(pageView));
      expect(_pages(tester).page, 2);

      await tester.tap(find.byType(Tab).at(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(_pages(tester).page, greaterThan(1));
      expect(_pages(tester).page, lessThan(2));
      reduced.value = true;
      await tester.pump();
      expect(_pages(tester).page, 1);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
