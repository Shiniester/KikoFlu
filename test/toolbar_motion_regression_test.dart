// Run with --dart-define=KIKOFLU_PERFORMANCE=true to include the download fixture.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/floating_feed_toolbar.dart';
import 'package:kikoeru_flutter/src/screens/local_downloads_screen.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/download_service.dart';
import 'package:kikoeru_flutter/src/models/download_task.dart';

Widget _app(Widget child, ValueNotifier<bool> reduced) => ProviderScope(
  child: MaterialApp(
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: ValueListenableBuilder<bool>(
      valueListenable: reduced,
      builder: (context, value, _) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: value),
        child: Scaffold(body: child),
      ),
    ),
  ),
);
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });
  testWidgets('active follower snaps on reduced motion', (tester) async {
    final reduced = ValueNotifier(false);
    final visible = ValueNotifier(true);
    addTearDown(reduced.dispose);
    addTearDown(visible.dispose);
    const child = SizedBox(key: ValueKey('target'), height: 40);
    await tester.pumpWidget(
      _app(
        Stack(
          children: [
            FloatingToolbarPositionFollower(
              primaryToolbarVisible: visible,
              visibleTop: 64,
              hiddenTop: 8,
              left: 8,
              right: 8,
              child: child,
            ),
          ],
        ),
        reduced,
      ),
    );
    visible.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final before = tester.getTopLeft(find.byKey(const ValueKey('target'))).dy;
    reduced.value = true;
    await tester.pump();
    final after = tester.getTopLeft(find.byKey(const ValueKey('target'))).dy;
    expect(before, inExclusiveRange(8, 64));
    expect(after, 8);
  });
  testWidgets('active download toolbar scale snaps on reduced motion', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await tester.pumpWidget(_app(const LocalDownloadsScreen(), reduced));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final transform = find
        .descendant(
          of: find.byKey(const ValueKey('downloads-toolbar-search')),
          matching: find.byType(Transform),
        )
        .first;
    final before = tester.widget<Transform>(transform).transform.entry(0, 0);
    final fieldElement = tester.element(find.byType(TextField));
    final focus = tester.widget<TextField>(find.byType(TextField)).focusNode!;
    final sizeFinder = find
        .ancestor(
          of: find.byKey(const ValueKey('downloads-toolbar-search')),
          matching: find.byType(AnimatedSize),
        )
        .first;
    final contentSize = tester.getSize(
      find.byKey(const ValueKey('downloads-toolbar-search')),
    );
    expect(tester.getSize(sizeFinder).width, lessThan(contentSize.width));
    reduced.value = true;
    await tester.pump();
    final after = tester.widget<Transform>(transform).transform.entry(0, 0);
    expect(before, inExclusiveRange(.97, 1));
    expect(after, 1);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('downloads-toolbar-search')),
        matching: find.byType(AnimatedSize),
      ),
      findsNothing,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('downloads-toolbar-search'))),
      contentSize,
    );
    expect(tester.element(find.byType(TextField)), same(fieldElement));
    expect(focus.hasFocus, isTrue);
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.widget<Transform>(transform).transform.entry(0, 0), 1);
    reduced.value = false;
    await tester.pump();
    expect(tester.widget<Transform>(transform).transform.entry(0, 0), 1);
    expect(tester.element(find.byType(TextField)), same(fieldElement));
    expect(focus.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'selection exit restores search focus',
    (tester) async {
      DownloadService.instance.debugInjectPerformanceTasks([
        DownloadTask(
          id: '1',
          workId: 1,
          workTitle: 'Sample',
          fileName: 'a.mp3',
          downloadUrl: 'https://example.invalid/a.mp3',
          createdAt: DateTime(2026),
          status: DownloadStatus.completed,
        ),
      ]);
      addTearDown(DownloadService.instance.debugClearPerformanceTasks);
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await tester.pumpWidget(_app(const LocalDownloadsScreen(), reduced));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.longPress(find.byKey(const ValueKey(1)));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    },
    skip: !const bool.fromEnvironment('KIKOFLU_PERFORMANCE'),
  );
}
