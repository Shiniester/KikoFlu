import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/library_page_scaffold.dart';
import 'package:kikoeru_flutter/src/widgets/settings_section.dart';

void main() {
  Widget app({
    VoidCallback? onSearch,
    VoidCallback? onSelect,
    VoidCallback? onSettings,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    bool longDrawer = true,
  }) => MaterialApp(
    theme: ThemeData(brightness: brightness),
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
          title: '来源',
          children: [
            LibraryDrawerTile(
              icon: Icons.public,
              title: 'ASMR.ONE',
              selected: true,
              onTap: () {},
            ),
          ],
        ),
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
            for (var i = 0; i < (longDrawer ? 20 : 0); i++)
              LibraryDrawerTile(
                icon: Icons.folder,
                title: '页面 $i',
                onTap: () {},
              ),
          ],
        ),
        LibraryDrawerSection(
          title: '浏览选项',
          children: [
            LibraryDrawerTile(icon: Icons.grid_view, title: '布局', onTap: () {}),
            LibraryDrawerTile(
              icon: Icons.closed_caption,
              title: '字幕筛选',
              selected: true,
              onTap: () {},
            ),
          ],
        ),
      ],
      drawerFooter: LibraryDrawerTile(
        icon: Icons.settings_outlined,
        title: '音声设置',
        onTap: onSettings ?? () {},
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
  });

  for (final width in [320.0, 1000.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'filled menu matches search color and margin ($width, $brightness)',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 640));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(app(brightness: brightness));
          final menu = find.byKey(const ValueKey('library-menu-button'));
          final title = find.byKey(const ValueKey('library-page-title'));
          final search = find.byKey(const ValueKey('library-page-search'));
          final button = tester.widget<FilledButton>(menu);
          final searchMaterial = tester.widget<Material>(
            find.ancestor(of: search, matching: find.byType(Material)).first,
          );
          expect(button.style!.side!.resolve({}), BorderSide.none);
          expect(
            button.style!.backgroundColor!.resolve({}),
            searchMaterial.color,
          );
          expect(
            (button.style!.shape!.resolve({})! as RoundedRectangleBorder)
                .borderRadius,
            searchMaterial.borderRadius,
          );
          expect(find.descendant(of: menu, matching: title), findsOneWidget);
          expect(
            find.descendant(of: menu, matching: find.byIcon(Icons.menu)),
            findsOneWidget,
          );
          expect(tester.getTopLeft(menu).dx, 12);
          expect(
            tester.getTopLeft(menu).dx,
            width - tester.getTopRight(search).dx,
          );
          await tester.tap(title);
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('library-drawer')), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'drawer uses settings background and contrasting cards ($brightness)',
      (tester) async {
        await tester.pumpWidget(app(longDrawer: false, brightness: brightness));
        await tester.tap(find.byKey(const ValueKey('library-menu-button')));
        await tester.pumpAndSettle();
        final drawer = find.byKey(const ValueKey('library-drawer'));
        final background = tester
            .widget<Material>(
              find
                  .descendant(of: drawer, matching: find.byType(Material))
                  .first,
            )
            .color;
        expect(
          background,
          Theme.of(tester.element(drawer)).scaffoldBackgroundColor,
        );
        expect(
          find.descendant(
            of: drawer,
            matching: find.byType(SettingsSectionCard),
          ),
          findsNWidgets(3),
        );
        for (final title in ['来源', '页面', '浏览选项']) {
          final section = find.ancestor(
            of: find.text(title),
            matching: find.byType(LibraryDrawerSection),
          );
          final card = find.descendant(
            of: section,
            matching: find.byType(Card),
          );
          expect(
            find.descendant(of: card, matching: find.text(title)),
            findsOneWidget,
          );
          final widget = tester.widget<Card>(card);
          final cardColor = tester
              .widget<Material>(
                find
                    .descendant(of: card, matching: find.byType(Material))
                    .first,
              )
              .color;
          expect(cardColor, isNot(background));
          expect(widget.margin, EdgeInsets.zero);
          expect(widget.clipBehavior, Clip.antiAlias);
          expect(widget.shape, isA<RoundedRectangleBorder>());
          final heading = find.text(title);
          final headingStyle = tester.widget<Text>(heading).style!;
          expect(headingStyle.fontSize, 12);
          expect(
            headingStyle.color,
            Theme.of(tester.element(heading)).colorScheme.onSurfaceVariant,
          );
          final divider = find.descendant(
            of: section,
            matching: find.byType(Divider),
          );
          final line = tester.widget<Divider>(divider);
          expect(line.thickness, 0.6);
          expect(line.indent, 12);
          expect(line.endIndent, 12);
          final cardRect = tester.getRect(card);
          final dividerRect = tester.getRect(divider);
          final headingRect = tester.getRect(heading);
          expect(headingRect.top - cardRect.top, 12);
          expect(
            headingRect.center.dy,
            closeTo((cardRect.top + dividerRect.center.dy) / 2, 0.5),
          );
          expect(dividerRect.left + line.indent!, greaterThan(cardRect.left));
          expect(dividerRect.right - line.endIndent!, lessThan(cardRect.right));
        }
        for (final title in ['ASMR.ONE', '历史', '字幕筛选']) {
          final text = find.text(title);
          final tile = tester.widget<ListTile>(
            find.widgetWithText(ListTile, title),
          );
          final primary = Theme.of(tester.element(text)).colorScheme.primary;
          expect(tile.selectedTileColor, Colors.transparent);
          expect(
            DefaultTextStyle.of(tester.element(text)).style.color,
            primary,
          );
          expect(tester.widget<Text>(text).style!.fontWeight, FontWeight.bold);
          final icon = find.descendant(
            of: find.widgetWithText(ListTile, title),
            matching: find.byType(Icon),
          );
          expect(IconTheme.of(tester.element(icon)).color, primary);
        }
        expect(
          tester.getSize(find.byKey(const ValueKey('history-row'))).height,
          48,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('compact drawer scrolls to settings without selected checks', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var opened = false;
    await tester.pumpWidget(app(onSettings: () => opened = true));
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    final drawer = find.byKey(const ValueKey('library-drawer'));
    expect(tester.getSize(drawer).width, 224);
    expect(
      tester.getSize(find.byKey(const ValueKey('history-row'))).height,
      48,
    );
    final history = find.text('历史');
    expect(tester.widget<Text>(history).style!.fontSize, 16);
    expect(tester.widget<Text>(find.text('页面')).style!.fontSize, 12);
    expect(tester.getSize(find.text('页面')).height, 16);
    expect(
      DefaultTextStyle.of(tester.element(history)).style.color,
      Theme.of(tester.element(history)).colorScheme.primary,
    );
    expect(
      find.descendant(of: drawer, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
    final footer = find.text('音声设置');
    final drawerList = find.descendant(
      of: drawer,
      matching: find.byType(ListView),
    );
    expect(footer.hitTestable(), findsNothing);
    await tester.scrollUntilVisible(
      footer,
      300,
      scrollable: find.descendant(
        of: drawerList,
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.descendant(of: drawerList, matching: footer), findsOneWidget);
    expect(footer.hitTestable(), findsOneWidget);
    await tester.tap(footer);
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    expect(footer, findsNothing);
    expect(tester.takeException(), isNull);
  });

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
