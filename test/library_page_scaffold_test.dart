import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/library_page_scaffold.dart';

void main() {
  Widget app({
    VoidCallback? onSearch,
    VoidCallback? onSelect,
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
      title: '热门',
      searchHint: '搜索热门',
      onSearch: onSearch ?? () {},
      drawerChildren: [
        LibraryDrawerSection(
          title: '页面',
          children: [
            LibraryDrawerTile(
              key: const ValueKey('history-row'),
              icon: Icons.history,
              title: '历史',
              selected: true,
              onTap: onSelect ?? () {},
            ),
            for (var i = 0; i < 20; i++)
              LibraryDrawerTile(
                icon: Icons.folder,
                title: '页面 $i',
                onTap: () {},
              ),
          ],
        ),
      ],
      drawerFooter: LibraryDrawerTile(
        icon: Icons.settings_outlined,
        title: '音声设置',
        onTap: () {},
      ),
      body: ListView.builder(
        itemCount: 80,
        itemBuilder: (_, index) => ListTile(title: Text('作品 $index')),
      ),
    ),
  );

  testWidgets('header stays fixed and title precedes search entry', (
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

  testWidgets('search entry opens search without an editor or keyboard', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(app(onSearch: () => opened++));
    await tester.tap(find.byKey(const ValueKey('library-page-search')));
    await tester.pump();
    expect(opened, 1);
    expect(find.byType(EditableText), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    final menu = tester.widget<IconButton>(
      find.byKey(const ValueKey('library-menu-button')),
    );
    expect(menu.isSelected, isNull);
    expect(menu.style, isNull);
  });

  testWidgets(
    'compact drawer keeps settings at bottom without selected checks',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app());
      await tester.tap(find.byKey(const ValueKey('library-menu-button')));
      await tester.pumpAndSettle();
      final drawer = find.byKey(const ValueKey('library-drawer'));
      expect(tester.getSize(drawer).width, 256);
      expect(
        tester.getSize(find.byKey(const ValueKey('history-row'))).height,
        48,
      );
      expect(
        find.descendant(of: drawer, matching: find.byIcon(Icons.check)),
        findsNothing,
      );
      final footer = find.text('音声设置');
      final bottom = tester.getTopLeft(footer);
      await tester.drag(
        find.descendant(of: drawer, matching: find.byType(ListView)),
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(footer), bottom);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('drawer navigation closes before selecting a page', (
    tester,
  ) async {
    var selected = false;
    await tester.pumpWidget(app(onSelect: () => selected = true));
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(selected, isTrue);
    expect(find.text('历史'), findsNothing);
  });

  testWidgets('narrow header supports large text without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(textScale: 2));
    expect(find.byKey(const ValueKey('library-page-search')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
