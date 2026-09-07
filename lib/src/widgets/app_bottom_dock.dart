import 'package:flutter/material.dart';

import 'app_bottom_dock_transition.dart';

class AppBottomDock extends StatelessWidget {
  const AppBottomDock({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.miniPlayer,
  });

  static const double navigationBarHeight = appBottomDockNavigationBarHeight;

  static double layoutExtent(BuildContext context) {
    return navigationBarHeight +
        AppBottomDockTransitionScope.bottomInsetOf(context);
  }

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;
  final Widget? miniPlayer;

  @override
  Widget build(BuildContext context) {
    final navigationBarExtent = layoutExtent(context);
    final frozenBottomInset = AppBottomDockTransitionScope.handoffBottomInsetOf(
      context,
    );
    Widget navigationBar = SizedBox(
      width: double.infinity,
      height: navigationBarExtent,
      child: NavigationBar(
        height: navigationBarHeight,
        maintainBottomViewPadding: true,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        selectedIndex: selectedIndex,
        onDestinationSelected: onDestinationSelected,
        destinations: destinations,
      ),
    );
    if (frozenBottomInset != null) {
      navigationBar = AppBottomDockTransitionScope.withHandoffBottomInset(
        context,
        bottomInset: frozenBottomInset,
        child: navigationBar,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (miniPlayer case final miniPlayer?)
          AppBottomDockMiniPlayerHero.source(child: miniPlayer),
        AppBottomDockTabBarHero.source(child: navigationBar),
      ],
    );
  }
}
