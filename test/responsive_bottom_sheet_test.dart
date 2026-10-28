import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/widgets/file_selection_dialog.dart';
import 'package:kikoeru_flutter/src/widgets/responsive_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _surfaceKey = ValueKey('responsive-sheet-surface');

Widget _testApp(Widget home) {
  return ProviderScope(
    child: MaterialApp(
      theme: ThemeData(platform: TargetPlatform.iOS),
      locale: const Locale('en'),
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      home: home,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('responsive bottom sheet is dismissible by tapping the barrier', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showResponsiveBottomSheet<void>(
                context: context,
                builder: (context) => const BottomSheetMenu(
                  children: [ListTile(title: Text('Sheet action'))],
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Sheet action'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Sheet action'), findsNothing);
  });

  testWidgets('download selector uses the shared sheet without nested dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showResponsiveBottomSheet<void>(
                context: context,
                builder: (context) => const FileSelectionDialog(
                  work: Work(id: 1, title: 'Download test', children: []),
                ),
              ),
              child: const Text('Download'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Select Files to Download'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);

    final cancelButton = find.widgetWithText(TextButton, 'Cancel');
    final downloadButton = find.widgetWithText(FilledButton, 'Download (0)');
    expect(cancelButton, findsOneWidget);
    expect(downloadButton, findsOneWidget);
    expect(tester.getSize(cancelButton), tester.getSize(downloadButton));
    expect(
      find.descendant(
        of: downloadButton,
        matching: find.byIcon(Icons.download),
      ),
      findsNothing,
    );

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Select Files to Download'), findsNothing);
  });

  testWidgets('landscape sheet slides in from the right and fills the height', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showResponsiveBottomSheet<void>(
                context: context,
                builder: (_) => const Text('Landscape sheet'),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump(const Duration(milliseconds: 50));
    final enteringRect = tester.getRect(find.byKey(_surfaceKey));
    await tester.pumpAndSettle();

    final settledRect = tester.getRect(find.byKey(_surfaceKey));
    expect(enteringRect.left, greaterThan(settledRect.left));
    expect(settledRect.right, closeTo(844, 0.1));
    expect(settledRect.height, closeTo(390, 0.1));
  });

  testWidgets('landscape sheet keeps the theme radius at its bottom left', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _testApp(
        Theme(
          data: ThemeData(
            bottomSheetTheme: const BottomSheetThemeData(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
            ),
          ),
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showResponsiveBottomSheet<void>(
                  context: context,
                  builder: (_) => const Text('Landscape sheet'),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final sheet = tester.widget<BottomSheet>(find.byKey(_surfaceKey));
    final radius = (sheet.shape! as RoundedRectangleBorder).borderRadius
        .resolve(TextDirection.ltr);
    expect(radius.topLeft, const Radius.circular(20));
    expect(radius.bottomLeft, radius.topLeft);
    expect(radius.bottomRight, Radius.zero);
  });

  testWidgets('updates the live height limit without resizing the window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final maxHeight = ValueNotifier(180.0);
    addTearDown(maxHeight.dispose);
    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showResponsiveBottomSheet<void>(
                context: context,
                maxHeight: 300,
                maxHeightListenable: maxHeight,
                builder: (_) => BottomSheetMenu(
                  children: List.generate(
                    20,
                    (index) => ListTile(title: Text('Action $index')),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_surfaceKey)).height, closeTo(180, 0.1));

    maxHeight.value = 120;
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(_surfaceKey));
    expect(rect.height, closeTo(120, 0.1));
    expect(rect.right, closeTo(844, 0.1));
  });

  for (final testCase in [
    (maxWidth: null, expectedWidth: 640.0),
    (maxWidth: 360.0, expectedWidth: 360.0),
  ]) {
    testWidgets('portrait sheet width is ${testCase.expectedWidth}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _testApp(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showResponsiveBottomSheet<void>(
                  context: context,
                  maxWidth: testCase.maxWidth,
                  builder: (_) => const Text('Portrait sheet'),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(_surfaceKey));
      expect(rect.width, closeTo(testCase.expectedWidth, 0.1));
      expect(rect.center.dx, closeTo(400, 0.1));
    });
  }

  testWidgets('rotation preserves sheet state, selection, and scroll offset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final sheetKey = GlobalKey<_PersistentSheetContentState>();
    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showResponsiveBottomSheet<void>(
                context: context,
                builder: (_) => _PersistentSheetContent(key: sheetKey),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep selection'));
    await tester.pump();
    await tester.drag(
      find.byKey(_PersistentSheetContentState.listKey),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    final state = sheetKey.currentState!;
    final scrollOffset = state.scrollController.offset;
    expect(state.isSelected, isTrue);
    expect(scrollOffset, greaterThan(0));

    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();

    expect(sheetKey.currentState, same(state));
    expect(state.isSelected, isTrue);
    expect(state.scrollController.offset, closeTo(scrollOffset, 0.1));
    expect(tester.getRect(find.byKey(_surfaceKey)).right, closeTo(844, 0.1));
  });

  testWidgets('returns a result on the nearest navigator', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final rootObserver = _CountingNavigatorObserver();
    final nestedObserver = _CountingNavigatorObserver();
    Future<String?>? result;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [rootObserver],
        home: Navigator(
          observers: [nestedObserver],
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () {
                    result = showResponsiveBottomSheet<String>(
                      context: context,
                      builder: (sheetContext) => TextButton(
                        onPressed: () =>
                            Navigator.of(sheetContext).pop('selected'),
                        child: const Text('Return result'),
                      ),
                    );
                  },
                  child: const Text('Open nested sheet'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    rootObserver.reset();
    nestedObserver.reset();

    await tester.tap(find.text('Open nested sheet'));
    await tester.pumpAndSettle();
    expect(nestedObserver.pushCount, 1);
    expect(rootObserver.pushCount, 0);

    await tester.tap(find.text('Return result'));
    await tester.pumpAndSettle();

    expect(await result, 'selected');
    expect(nestedObserver.popCount, 1);
    expect(rootObserver.popCount, 0);
  });

  testWidgets('a non-dismissible sheet ignores the barrier but accepts back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<String?>? result;
    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                result = showResponsiveBottomSheet<String>(
                  context: context,
                  isDismissible: false,
                  builder: (sheetContext) => TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop('closed'),
                    child: const Text('Close sheet'),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Close sheet'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Close sheet'), findsNothing);
    expect(await result, isNull);
  });

  testWidgets('long landscape menus scroll within the side panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(650, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showResponsiveBottomSheet<void>(
                context: context,
                builder: (_) => BottomSheetMenu(
                  children: List.generate(
                    30,
                    (index) => ListTile(title: Text('Menu option $index')),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final lastOption = find.text('Menu option 29');
    expect(lastOption, findsOneWidget);
    expect(
      tester.getRect(lastOption).bottom,
      greaterThan(tester.getRect(find.byKey(_surfaceKey)).bottom),
    );

    await tester.scrollUntilVisible(lastOption, 120);
    expect(
      tester.getRect(lastOption).bottom,
      lessThanOrEqualTo(tester.getRect(find.byKey(_surfaceKey)).bottom),
    );
  });

  testWidgets('portrait sheet can still be dismissed by dragging down', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showResponsiveBottomSheet<void>(
                context: context,
                builder: (_) => const SizedBox(
                  height: 240,
                  child: Center(child: Text('Drag to dismiss')),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(_surfaceKey), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(find.text('Drag to dismiss'), findsNothing);
  });

  testWidgets('scroll control and drag options affect the portrait sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showResponsiveBottomSheet<void>(
                context: context,
                isScrollControlled: false,
                enableDrag: false,
                builder: (_) => const SizedBox(
                  height: 700,
                  child: Center(child: Text('Fixed height sheet')),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final surface = find.byKey(_surfaceKey);
    expect(tester.getRect(surface).height, lessThanOrEqualTo(844 * 9 / 16));

    await tester.drag(surface, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text('Fixed height sheet'), findsOneWidget);
  });

  testWidgets('captures the local theme and moves above the keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => Theme(
            data: ThemeData(
              brightness: Brightness.dark,
              platform: TargetPlatform.iOS,
              bottomSheetTheme: const BottomSheetThemeData(
                backgroundColor: Colors.deepPurple,
              ),
            ),
            child: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showResponsiveBottomSheet<void>(
                    context: context,
                    builder: (sheetContext) =>
                        Text('Theme: ${Theme.of(sheetContext).brightness}'),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final surface = find.byKey(_surfaceKey);
    expect(find.text('Theme: Brightness.dark'), findsOneWidget);
    final material = tester.widget<Material>(
      find.descendant(of: surface, matching: find.byType(Material)).first,
    );
    expect(material.color, Colors.deepPurple);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.getRect(surface).bottom, lessThanOrEqualTo(544));
  });
}

class _PersistentSheetContent extends StatefulWidget {
  const _PersistentSheetContent({super.key});

  @override
  State<_PersistentSheetContent> createState() =>
      _PersistentSheetContentState();
}

class _PersistentSheetContentState extends State<_PersistentSheetContent> {
  static const listKey = ValueKey('persistent-sheet-list');

  final scrollController = ScrollController();
  bool isSelected = false;

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        children: [
          CheckboxListTile(
            title: const Text('Keep selection'),
            value: isSelected,
            onChanged: (value) => setState(() => isSelected = value ?? false),
          ),
          Expanded(
            child: ListView.builder(
              key: listKey,
              controller: scrollController,
              itemCount: 40,
              itemBuilder: (context, index) =>
                  ListTile(title: Text('Persistent row $index')),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountingNavigatorObserver extends NavigatorObserver {
  int pushCount = 0;
  int popCount = 0;

  void reset() {
    pushCount = 0;
    popCount = 0;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount++;
  }
}
