import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/floating_feed_toolbar.dart';

Widget _testApp(Widget child, {double width = 390}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(width: width, child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('renders classic Material capsules with interactive actions', (
    tester,
  ) async {
    var selectedMode = '';
    var toolTaps = 0;

    await tester.pumpWidget(
      _testApp(
        FloatingFeedToolbar(
          modeActions: [
            FloatingFeedModeAction(
              icon: Icons.grid_view,
              iconAsset: 'assets/icons/comic_source_ehentai.png',
              label: 'All',
              isSelected: true,
              onPressed: () => selectedMode = 'all',
            ),
            FloatingFeedModeAction(
              icon: Icons.local_fire_department,
              label: 'Popular',
              isSelected: false,
              onPressed: () => selectedMode = 'popular',
            ),
          ],
          toolActions: [
            FloatingFeedToolAction(
              icon: Icons.closed_caption,
              tooltip: 'Subtitles',
              isSelected: true,
              onPressed: () => toolTaps++,
            ),
          ],
        ),
      ),
    );

    expect(find.byKey(const ValueKey('feed-mode-capsule')), findsOneWidget);
    expect(find.byKey(const ValueKey('feed-tool-capsule')), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    final modeIcon = tester.widget<Image>(find.byType(Image));
    expect(modeIcon.image, isA<AssetImage>());
    expect(modeIcon.color, isNull);
    expect(
      tester.widget<Text>(find.text('All')).style?.color,
      Theme.of(tester.element(find.text('All'))).colorScheme.primary,
    );
    final surfaceMaterial = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(const ValueKey('feed-mode-capsule')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(
      surfaceMaterial.color?.a,
      closeTo(FloatingToolbarSurface.backgroundOpacity, 0.001),
    );

    await tester.tap(find.text('Popular'));
    await tester.tap(find.byTooltip('Subtitles'));
    expect(selectedMode, 'popular');
    expect(toolTaps, 1);
  });

  testWidgets('animates a bounded menu when modes do not fit', (tester) async {
    var selectedMode = -1;
    await tester.pumpWidget(
      _testApp(
        FloatingFeedToolbar(
          modeActions: [
            for (var index = 0; index < 8; index++)
              FloatingFeedModeAction(
                icon: Icons.filter_alt,
                iconAsset: index == 0
                    ? 'assets/icons/comic_source_ehentai.png'
                    : null,
                label: index == 7
                    ? 'Filter option 7 long'
                    : 'Filter option $index',
                isSelected: index == 0,
                onPressed: () => selectedMode = index,
              ),
          ],
          toolActions: [
            FloatingFeedToolAction(
              icon: Icons.sort,
              tooltip: 'Sort',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );

    expect(find.byKey(const ValueKey('feed-mode-dropdown')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('feed-mode-dropdown')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final menuItems = find.byType(MenuItemButton);
    final buttons = tester.widgetList<MenuItemButton>(menuItems).toList();
    final selectedButton = buttons.singleWhere((button) => button.autofocus);
    final unselectedButton = buttons.firstWhere((button) => !button.autofocus);
    final colors = Theme.of(tester.element(menuItems.first)).colorScheme;
    expect(
      selectedButton.style?.foregroundColor?.resolve({}),
      colors.onPrimaryContainer,
    );
    expect(
      selectedButton.style?.backgroundColor?.resolve({}),
      colors.primaryContainer,
    );
    expect(unselectedButton.style?.foregroundColor?.resolve({}), isNull);
    expect(unselectedButton.style?.backgroundColor?.resolve({}), isNull);
    expect(
      find.descendant(of: menuItems, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
    expect(find.byType(Image), findsNWidgets(2));
    expect(
      tester
          .widgetList<Image>(find.byType(Image))
          .every((image) => image.image is AssetImage && image.color == null),
      isTrue,
    );
    expect(
      tester
          .widgetList<Text>(find.text('Filter option 0'))
          .singleWhere((text) => text.style?.fontWeight == FontWeight.w700)
          .style
          ?.color,
      colors.primary,
    );
    final selectedItem = find.widgetWithText(MenuItemButton, 'Filter option 1');
    final scale = find.ancestor(
      of: selectedItem,
      matching: find.byType(ScaleTransition),
    );
    expect(scale, findsNothing);
    final menu = find
        .ancestor(of: selectedItem, matching: find.byType(Material))
        .first;
    final openingHeight = tester.getSize(menu).height;
    expect(openingHeight, greaterThan(0));
    final fade = find.ancestor(
      of: selectedItem,
      matching: find.byType(FadeTransition),
    );
    expect(fade, findsAtLeastNWidgets(1));
    expect(
      tester.widget<FadeTransition>(fade.first).opacity.value,
      inExclusiveRange(0, 1),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(menu).height, greaterThan(openingHeight));
    expect(
      tester.getSize(menu).width,
      greaterThan(
        tester.getSize(find.byKey(const ValueKey('feed-mode-dropdown'))).width,
      ),
    );
    for (final text
        in find
            .descendant(
              of: find.byType(MenuItemButton),
              matching: find.byType(Text),
            )
            .evaluate()) {
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byWidget(text.widget),
      );
      final label = text.widget as Text;
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(
        paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: label.data!.length),
        ),
        hasLength(1),
      );
    }
    expect(find.text('Filter option 1'), findsOneWidget);
    await tester.tap(find.text('Filter option 1'));
    await tester.pumpAndSettle();
    expect(selectedMode, 1);

    await tester.tap(find.byKey(const ValueKey('feed-mode-dropdown')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
  });

  testWidgets('skips the menu entrance when reduced motion is enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 250,
              child: FloatingFeedToolbar(
                modeActions: [
                  for (var index = 0; index < 8; index++)
                    FloatingFeedModeAction(
                      icon: Icons.filter_alt,
                      label: 'Filter option $index',
                      isSelected: index == 0,
                      onPressed: () {},
                    ),
                ],
                toolActions: const [],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('feed-mode-dropdown')));
    await tester.pump();
    final selectedItem = find.widgetWithText(MenuItemButton, 'Filter option 0');
    final menu = find
        .ancestor(of: selectedItem, matching: find.byType(Material))
        .first;
    final openingHeight = tester.getSize(menu).height;
    expect(openingHeight, greaterThan(0));
    final fade = find.ancestor(
      of: selectedItem,
      matching: find.byType(FadeTransition),
    );
    expect(tester.widget<FadeTransition>(fade.first).opacity.value, 1);
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getSize(menu).height, openingHeight);
  });

  testWidgets('can keep every mode as scrolling buttons when requested', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        FloatingFeedToolbar(
          collapseModesWhenNeeded: false,
          modeActions: [
            for (var index = 0; index < 8; index++)
              FloatingFeedModeAction(
                icon: Icons.filter_alt,
                label: 'Filter option $index',
                isSelected: index == 0,
                onPressed: () {},
              ),
          ],
          toolActions: const [],
        ),
        width: 280,
      ),
    );

    expect(find.byKey(const ValueKey('feed-mode-scroll')), findsOneWidget);
    expect(find.byKey(const ValueKey('feed-mode-dropdown')), findsNothing);
  });

  testWidgets('secondary toolbar follows primary visibility', (tester) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      _testApp(
        Stack(
          children: [
            FloatingToolbarPositionFollower(
              primaryToolbarVisible: visible,
              visibleTop: 64,
              hiddenTop: 8,
              left: 8,
              right: 8,
              child: const SizedBox(height: 40),
            ),
          ],
        ),
      ),
    );

    expect(
      tester.widget<AnimatedPositioned>(find.byType(AnimatedPositioned)).top,
      64,
    );
    visible.value = false;
    await tester.pump();
    expect(
      tester.widget<AnimatedPositioned>(find.byType(AnimatedPositioned)).top,
      8,
    );
  });

  testWidgets('progressive top treatment avoids dynamic backdrop filters', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        const MediaQuery(
          data: MediaQueryData(padding: EdgeInsets.only(top: 24)),
          child: ProgressiveTopScrim(height: 48),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(DecoratedBox), findsOneWidget);
  });
}
