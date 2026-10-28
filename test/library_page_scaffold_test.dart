import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/library_page_scaffold.dart';
import 'package:kikoeru_flutter/src/widgets/settings_section.dart';

void main() {
  Widget app({
    VoidCallback? onSearch,
    VoidCallback? onSelect,
    VoidCallback? onAlternate,
    VoidCallback? onSettings,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    TargetPlatform? platform,
    Locale locale = const Locale('zh'),
    bool longDrawer = true,
    bool deferDrawerActions = false,
    bool closeOnTap = true,
    List<Widget> historyChildren = const [],
    Widget? body,
  }) => MaterialApp(
    theme: ThemeData(brightness: brightness, platform: platform),
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    locale: locale,
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
      deferDrawerActions: deferDrawerActions,
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
              closeOnTap: closeOnTap,
              onTap: onSelect ?? () {},
              children: historyChildren,
            ),
            if (onAlternate != null)
              LibraryDrawerTile(
                icon: Icons.bookmark_outline,
                title: '收藏',
                onTap: onAlternate,
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
      body:
          body ??
          ListView.builder(
            itemCount: 80,
            itemBuilder: (_, index) => ListTile(title: Text('作品 $index')),
          ),
    ),
  );

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    for (final width in [320.0, 1000.0]) {
      testWidgets('content right swipe opens drawer ($platform, $width)', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var selected = 0;
        await tester.pumpWidget(
          app(platform: platform, onSelect: () => selected++),
        );

        await tester.dragFrom(Offset(width / 2, 300), Offset(width / 3, 0));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('library-drawer')), findsOneWidget);
        expect(selected, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('left swipes and vertical scrolling do not open drawer', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.dragFrom(const Offset(400, 300), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-drawer')), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('作品 0'), findsNothing);
    expect(find.byKey(const ValueKey('library-drawer')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single rightward move opens drawer', (tester) async {
    await tester.pumpWidget(app());
    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(120, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('library-drawer')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal content keeps its own drag gesture', (tester) async {
    final scroll = ScrollController(initialScrollOffset: 300);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      app(
        body: ListView(
          controller: scroll,
          scrollDirection: Axis.horizontal,
          children: const [SizedBox(width: 1600)],
        ),
      ),
    );
    await tester.dragFrom(const Offset(400, 300), const Offset(180, 0));
    await tester.pumpAndSettle();

    expect(scroll.offset, lessThan(300));
    expect(find.byKey(const ValueKey('library-drawer')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final textScale in [1.0, 2.0]) {
    testWidgets(
      'page children are indented and keep tap behavior ($textScale)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var parentSelected = 0;
        var childSelected = 0;
        const childKey = ValueKey('nested-layout');
        await tester.pumpWidget(
          app(
            textScale: textScale,
            longDrawer: false,
            onSelect: () => parentSelected++,
            historyChildren: [
              LibraryDrawerTile(
                key: childKey,
                icon: Icons.grid_view,
                title: '布局',
                closeOnTap: false,
                onTap: () => childSelected++,
              ),
            ],
          ),
        );
        await tester.tap(find.byKey(const ValueKey('library-menu-button')));
        await tester.pumpAndSettle();
        final parent = find.widgetWithText(ListTile, '历史');
        final child = find.byKey(childKey);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('history-row')),
            matching: child,
          ),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(child).dx,
          greaterThan(tester.getTopLeft(parent).dx),
        );
        expect(
          tester.getTopLeft(child).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(parent).dy),
        );
        await tester.tap(child);
        await tester.pumpAndSettle();
        expect(childSelected, 1);
        expect(parentSelected, 0);
        expect(find.byKey(const ValueKey('library-drawer')), findsOneWidget);
        await tester.tap(find.text('历史'));
        await tester.pumpAndSettle();
        expect(parentSelected, 1);
        expect(find.byKey(const ValueKey('library-drawer')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final locale in [
    const Locale('en'),
    const Locale('ja'),
    const Locale('zh'),
  ]) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets('localized submenu labels fit ($locale, $textScale)', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final s = await S.delegate.load(locale);
        const sortKey = ValueKey('nested-sort');
        final selectedCount = s.selectedCount(1);
        await tester.pumpWidget(
          app(
            locale: locale,
            textScale: textScale,
            longDrawer: false,
            historyChildren: [
              LibraryDrawerTile(
                icon: Icons.add,
                title: s.createPlaylist,
                onTap: () {},
              ),
              LibraryDrawerTile(
                icon: Icons.cloud_outlined,
                title: s.comicOnlineFavorites,
                onTap: () {},
              ),
              LibraryDrawerTile(
                key: sortKey,
                icon: Icons.sort,
                title: s.sort,
                subtitle: Text(
                  s.sortRelease,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {},
              ),
              LibraryDrawerTile(
                icon: Icons.close,
                title: s.exitSelection,
                subtitle: Text(selectedCount),
                onTap: () {},
              ),
            ],
          ),
        );
        await tester.tap(find.byKey(const ValueKey('library-menu-button')));
        await tester.pumpAndSettle();
        final sort = find.byKey(sortKey);
        await tester.ensureVisible(sort);
        await tester.pumpAndSettle();
        expect(
          tester
              .getSize(find.descendant(of: sort, matching: find.text(s.sort)))
              .width,
          greaterThan(0),
        );
        final count = find.text(selectedCount);
        await tester.ensureVisible(count);
        await tester.pumpAndSettle();
        final paragraph = tester.renderObject<RenderParagraph>(count);
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: selectedCount.length),
        );
        expect(boxes, isNotEmpty);
        expect(
          boxes.every((box) => box.bottom <= paragraph.size.height),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('page child actions can wait until the drawer closes', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      app(
        longDrawer: false,
        deferDrawerActions: true,
        historyChildren: [
          LibraryDrawerTile(
            icon: Icons.delete_outline,
            title: '清空历史',
            onTap: () => selected++,
          ),
        ],
      ),
    );
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空历史'));
    expect(selected, 0);
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(find.byKey(const ValueKey('library-drawer')), findsNothing);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('drawer selection stays immediate by default', (tester) async {
    var selected = false;
    await tester.pumpWidget(app(onSelect: () => selected = true));
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史'));
    expect(selected, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('历史'), findsNothing);
  });

  testWidgets('closeOnTap false still selects immediately without closing', (
    tester,
  ) async {
    var selected = false;
    await tester.pumpWidget(
      app(
        deferDrawerActions: true,
        closeOnTap: false,
        onSelect: () => selected = true,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史'));

    expect(selected, isTrue);
    expect(find.text('历史'), findsOneWidget);
  });

  testWidgets(
    'deferred drawer selection is latest-wins without popping its page',
    (tester) async {
      final selections = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => LibraryPageScaffold(
                      title: 'Library page',
                      searchHint: 'Search',
                      onSearch: () {},
                      deferDrawerActions: true,
                      drawerChildren: [
                        LibraryDrawerTile(
                          icon: Icons.history,
                          title: 'First',
                          onTap: () => selections.add('first'),
                        ),
                        LibraryDrawerTile(
                          icon: Icons.bookmark_outline,
                          title: 'Second',
                          onTap: () => selections.add('second'),
                        ),
                      ],
                      body: const SizedBox.expand(),
                    ),
                  ),
                ),
                child: const Text('Parent page'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Parent page'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('First'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();

      expect(selections, ['second']);
      expect(find.text('Library page'), findsOneWidget);
      expect(find.text('Parent page'), findsNothing);
    },
  );

  testWidgets(
    'pending drawer action is canceled by reopening, inactivity, or disposal',
    (tester) async {
      var selected = 0;
      await tester.pumpWidget(
        app(deferDrawerActions: true, onSelect: () => selected++),
      );
      await tester.tap(find.byKey(const ValueKey('library-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('历史'));
      await tester.pump(const Duration(milliseconds: 60));
      final scaffold = tester.state<ScaffoldState>(
        find.ancestor(
          of: find.byKey(const ValueKey('library-menu-button')),
          matching: find.byType(Scaffold),
        ),
      );
      scaffold.openDrawer();
      await tester.pumpAndSettle();
      expect(selected, 0);

      await tester.tap(find.text('历史'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpWidget(
        app(deferDrawerActions: false, onSelect: () => selected++),
      );
      await tester.pumpAndSettle();
      expect(selected, 0);

      await tester.pumpWidget(
        app(deferDrawerActions: true, onSelect: () => selected++),
      );
      await tester.tap(find.byKey(const ValueKey('library-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('历史'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      expect(selected, 0);
    },
  );

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
