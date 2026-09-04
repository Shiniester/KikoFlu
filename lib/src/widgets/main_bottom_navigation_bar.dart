import 'package:flutter/material.dart';

import 'app_bottom_dock_transition.dart';

class MainBottomNavigationBar extends StatelessWidget {
  const MainBottomNavigationBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.miniPlayer,
  });

  static const double navigationBarHeight = 58;

  static double layoutExtent(BuildContext context) {
    return navigationBarHeight + MediaQuery.viewPaddingOf(context).bottom;
  }

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;
  final Widget? miniPlayer;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (miniPlayer case final miniPlayer?)
          AppBottomDockMiniPlayerHero.source(child: miniPlayer),
        AppBottomDockTabBarHero.source(
          child: NavigationBar(
            height: navigationBarHeight,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            selectedIndex: selectedIndex,
            onDestinationSelected: onDestinationSelected,
            destinations: destinations,
          ),
        ),
      ],
    );
  }
}
