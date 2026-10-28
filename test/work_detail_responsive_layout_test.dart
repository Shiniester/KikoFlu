import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_detail_responsive_layout.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/file_explorer_tree_panel.dart';

Widget _testApp({required Orientation orientation, required Widget child}) {
  final size = orientation == Orientation.landscape
      ? const Size(900, 500)
      : const Size(400, 800);

  return MaterialApp(
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Scaffold(body: child),
    ),
  );
}

void main() {
  for (final orientation in Orientation.values) {
    testWidgets('detail keeps a lazy single scroll in $orientation', (
      tester,
    ) async {
      var metadataBuilds = 0;
      await tester.pumpWidget(
        _testApp(
          orientation: orientation,
          child: WorkDetailResponsiveLayout(
            coverBuilder: (_, __) =>
                const SizedBox(height: 100, child: Text('cover')),
            infoSliver: SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverMainAxisGroup(
                slivers: [
                  const SliverToBoxAdapter(child: Text('info')),
                  FileExplorerTreePanel(
                    isLoading: false,
                    empty: false,
                    emptyMessage: 'Empty',
                    title: 'Files',
                    items: List.generate(
                      1000,
                      (i) => {'title': 'file-$i', 'type': 'file'},
                    ),
                    expandedFolders: const {},
                    onToggleFolder: (_) {},
                    onFileTap: (_, __, ___) {},
                    metadataBuilder: (_, __) {
                      metadataBuilds++;
                      return null;
                    },
                  ),
                  const SliverToBoxAdapter(child: Text('recommendations')),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.byType(Scrollable), findsOneWidget);
      expect(metadataBuilds, lessThan(40));
      await tester.scrollUntilVisible(
        find.text('recommendations'),
        2000,
        maxScrolls: 50,
      );
      expect(find.text('recommendations'), findsOneWidget);
      expect(find.text('file-999'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('last resource scrolls above the shared Dock', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          extendBody: true,
          bottomNavigationBar: const SizedBox(
            key: ValueKey('dock'),
            height: 120,
          ),
          body: WorkDetailResponsiveLayout(
            coverBuilder: (_, __) => const SizedBox(height: 100),
            infoSliver: SliverList.builder(
              itemCount: 20,
              itemBuilder: (_, index) => ListTile(title: Text('file-$index')),
            ),
          ),
        ),
      ),
    );

    final resource = find.text('file-19');
    await tester.scrollUntilVisible(resource, 500);
    await tester.pumpAndSettle();

    expect(
      tester.getBottomLeft(resource).dy,
      lessThanOrEqualTo(
        tester.getTopLeft(find.byKey(const ValueKey('dock'))).dy,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses a vertical scrolling layout in portrait', (tester) async {
    await tester.pumpWidget(
      _testApp(
        orientation: Orientation.portrait,
        child: WorkDetailResponsiveLayout(
          coverBuilder: (context, isLandscape) =>
              Text(isLandscape ? 'landscape-cover' : 'portrait-cover'),
          infoSliver: const SliverToBoxAdapter(child: Text('info')),
        ),
      ),
    );

    expect(find.text('portrait-cover'), findsOneWidget);
    expect(find.text('info'), findsOneWidget);
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsNothing);
  });

  testWidgets('uses a split scrolling layout in landscape', (tester) async {
    await tester.pumpWidget(
      _testApp(
        orientation: Orientation.landscape,
        child: WorkDetailResponsiveLayout(
          coverBuilder: (context, isLandscape) =>
              Text(isLandscape ? 'landscape-cover' : 'portrait-cover'),
          infoSliver: const SliverToBoxAdapter(child: Text('info')),
        ),
      ),
    );

    expect(find.text('landscape-cover'), findsOneWidget);
    expect(find.text('info'), findsOneWidget);
    expect(find.byType(Row), findsOneWidget);
    expect(find.byType(Expanded), findsNWidgets(2));
    expect(find.byType(CustomScrollView), findsOneWidget);
  });

  testWidgets('wraps the active scroll view with refresh when provided', (
    tester,
  ) async {
    var refreshCount = 0;

    await tester.pumpWidget(
      _testApp(
        orientation: Orientation.portrait,
        child: WorkDetailResponsiveLayout(
          coverBuilder: (context, isLandscape) => const Text('cover'),
          infoSliver: const SliverToBoxAdapter(child: Text('info')),
          onRefresh: () async => refreshCount++,
        ),
      ),
    );

    expect(find.byType(RefreshIndicator), findsOneWidget);

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 300),
      1000,
    );
    await tester.pumpAndSettle();

    expect(refreshCount, 1);
  });
}
