import 'package:flutter/material.dart';

class AppBottomDock extends StatelessWidget {
  const AppBottomDock({
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
    final navigationBarExtent = layoutExtent(context);
    final navigationBar = SizedBox(
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (miniPlayer case final miniPlayer?) miniPlayer,
        navigationBar,
      ],
    );
  }
}
