import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';

const _destinations = [
  NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
  NavigationDestination(icon: Icon(Icons.search_outlined), label: 'Search'),
];

void main() {
  testWidgets('keeps the home indicator safe area below navigation content', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          padding: EdgeInsets.only(bottom: 34),
          viewPadding: EdgeInsets.only(bottom: 34),
        ),
        child: MaterialApp(
          home: Scaffold(
            bottomNavigationBar: AppBottomDock(
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              destinations: _destinations,
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(AppBottomDock)).height,
      AppBottomDock.navigationBarHeight + 34,
    );
    expect(
      AppBottomDock.layoutExtent(tester.element(find.byType(AppBottomDock))),
      AppBottomDock.navigationBarHeight + 34,
    );
  });

  testWidgets(
    'uses classic Material navigation and keeps Mini Player above it',
    (tester) async {
      var selected = -1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: AppBottomDock(
              selectedIndex: 0,
              onDestinationSelected: (value) => selected = value,
              destinations: _destinations,
              miniPlayer: const SizedBox(
                key: ValueKey('mini-player'),
                height: 72,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byKey(const ValueKey('mini-player')), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('mini-player'))).dy,
        lessThan(tester.getTopLeft(find.byType(NavigationBar)).dy),
      );

      await tester.tap(find.text('Search'));
      expect(selected, 1);
    },
  );
}
