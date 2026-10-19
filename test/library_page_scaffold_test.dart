import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/library_page_scaffold.dart';

void main() {
  Widget app({
    String title = '热门',
    String hint = '搜索热门',
    ValueChanged<String>? onSearch,
    VoidCallback? onSelect,
    VoidCallback? onSearchCleared,
    Object? searchScopeKey,
    String? searchQuery,
    double textScale = 1,
  }) => MaterialApp(
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    locale: const Locale('zh'),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: LibraryPageScaffold(
      title: title,
      searchHint: hint,
      onSearch: onSearch ?? (_) {},
      onSearchCleared: onSearchCleared,
      searchScopeKey: searchScopeKey,
      searchQuery: searchQuery,
      drawerChildren: [
        LibraryDrawerSection(
          title: '页面',
          children: [
            LibraryDrawerTile(
              icon: Icons.history,
              title: '历史',
              onTap: onSelect ?? () {},
            ),
          ],
        ),
      ],
      body: ListView.builder(
        itemCount: 80,
        itemBuilder: (_, index) => ListTile(title: Text('作品 $index')),
      ),
    ),
  );

  testWidgets('header stays fixed and title precedes scoped search', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    final header = find.byKey(const ValueKey('library-page-header'));
    final search = find.byKey(const ValueKey('library-page-search'));
    final title = find.byKey(const ValueKey('library-page-title'));
    final before = tester.getTopLeft(header);
    expect(
      tester.getTopRight(title).dx,
      lessThan(tester.getTopLeft(search).dx),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header), before);
    expect(find.text('作品 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search submits trimmed text and clears when scope changes', (
    tester,
  ) async {
    final submitted = <String>[];
    await tester.pumpWidget(app(onSearch: submitted.add));
    final search = find.byKey(const ValueKey('library-page-search'));
    await tester.enterText(search, '  ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    expect(submitted, isEmpty);
    await tester.enterText(search, '  耳语  ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    expect(submitted, ['耳语']);
    await tester.pumpWidget(
      app(title: '历史', hint: '搜索历史', onSearch: submitted.add),
    );
    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
    expect(find.text('搜索历史'), findsOneWidget);
  });

  testWidgets('drawer navigation closes before selecting a page', (
    tester,
  ) async {
    var selected = false;
    await tester.pumpWidget(app(onSelect: () => selected = true));
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    expect(find.text('历史'), findsOneWidget);
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(selected, isTrue);
    expect(find.text('历史'), findsNothing);
  });

  testWidgets('clear resets local filters and source changes reset input', (
    tester,
  ) async {
    var cleared = 0;
    await tester.pumpWidget(
      app(searchScopeKey: 'one', onSearchCleared: () => cleared++),
    );
    final search = find.byKey(const ValueKey('library-page-search'));
    await tester.enterText(search, '耳语');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(cleared, 1);
    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
    await tester.enterText(search, '耳语');
    await tester.pumpWidget(app(searchScopeKey: 'jp'));
    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
  });

  testWidgets('local page navigation can reset the visible search query', (
    tester,
  ) async {
    await tester.pumpWidget(app(searchQuery: '字幕'));
    final search = find.byKey(const ValueKey('library-page-search'));
    expect(tester.widget<TextField>(search).controller!.text, '字幕');
    await tester.pumpWidget(app(searchQuery: ''));
    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
  });

  testWidgets('narrow header supports large text without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(title: '字幕', hint: '搜索字幕', textScale: 2));
    expect(find.byKey(const ValueKey('library-page-search')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
