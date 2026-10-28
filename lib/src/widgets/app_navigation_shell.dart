import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../providers/audio_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/update_provider.dart';
import 'app_bottom_dock.dart';
import 'app_navigation_scope.dart';
import 'mini_player.dart';

class AppNavigationShell extends StatelessWidget {
  const AppNavigationShell({
    super.key,
    required this.controller,
    required this.child,
  });

  final AppNavigationController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => Overlay.wrap(
    child: AppNavigationScope(
      controller: controller,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) =>
            Consumer(builder: (context, ref, _) => _buildShell(context, ref)),
      ),
    ),
  );

  Widget _buildShell(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final visible = controller.navigationVisible;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final showUpdateBadge = ref.watch(showUpdateRedDotProvider);
    final destinations = [
      NavigationDestination(
        icon: const Icon(Icons.library_music_outlined),
        selectedIcon: const Icon(Icons.library_music),
        label: s.navMy,
      ),
      NavigationDestination(
        icon: const Icon(Icons.menu_book_outlined),
        selectedIcon: const Icon(Icons.menu_book),
        label: s.navComics,
      ),
      NavigationDestination(
        icon: const Icon(Icons.video_library_outlined),
        selectedIcon: const Icon(Icons.video_library),
        label: s.navVideos,
      ),
      NavigationDestination(
        icon: Badge(
          isLabelVisible: showUpdateBadge,
          child: const Icon(Icons.settings_outlined),
        ),
        selectedIcon: Badge(
          isLabelVisible: showUpdateBadge,
          child: const Icon(Icons.settings),
        ),
        label: s.navSettings,
      ),
    ];
    final auth = ref.watch(authProvider);
    final offline =
        visible &&
        controller.selectedIndex == 0 &&
        auth.currentUser != null &&
        !auth.isLoggedIn &&
        auth.error != null;
    final transition = controller.fullscreenTransition;
    final layoutVisible =
        visible || (transition != null && transition.value < 1);
    final miniPlayer = layoutVisible
        ? ref
              .watch(currentTrackProvider)
              .when<Widget?>(
                data: (track) => track == null ? null : const MiniPlayer(),
                loading: () => null,
                error: (_, __) => null,
              )
        : null;
    void selectTab(int index) {
      if (index == controller.selectedIndex) return;
      controller.selectTab(index);
      if (index == 3) {
        ref.read(settingsCacheRefreshTriggerProvider.notifier).state++;
      }
    }

    final safePadding = MediaQuery.paddingOf(context);
    Widget buildFrame(BuildContext context) => _buildShellFrame(
      context,
      isLandscape: isLandscape,
      offline: offline,
      miniPlayer: miniPlayer,
      destinations: destinations,
      selectTab: selectTab,
      ref: ref,
      progress: transition?.value ?? 0,
      safePadding: safePadding,
    );
    return AnimatedBuilder(
      animation: transition ?? const AlwaysStoppedAnimation<double>(0),
      builder: (context, _) => buildFrame(context),
    );
  }

  Widget _buildShellFrame(
    BuildContext context, {
    required bool isLandscape,
    required bool offline,
    required Widget? miniPlayer,
    required List<NavigationDestination> destinations,
    required ValueChanged<int> selectTab,
    required WidgetRef ref,
    required double progress,
    required EdgeInsets safePadding,
  }) {
    final visible = controller.navigationVisible;
    final layoutVisible =
        visible || (controller.fullscreenTransition != null && progress < 1);
    final showOffline = offline && visible;
    Widget content = child;
    if (layoutVisible && isLandscape) {
      final showRail = progress < 1;
      content = Row(
        children: [
          if (showRail)
            ClipRect(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: 1 - progress,
                child: _protectNavigation(
                  SafeArea(
                    child: SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight:
                              MediaQuery.sizeOf(context).height -
                              MediaQuery.paddingOf(context).vertical,
                        ),
                        child: IntrinsicHeight(
                          child: NavigationRail(
                            selectedIndex: controller.selectedIndex,
                            onDestinationSelected: selectTab,
                            labelType: NavigationRailLabelType.selected,
                            destinations: [
                              for (final destination in destinations)
                                NavigationRailDestination(
                                  icon: destination.icon,
                                  selectedIcon: destination.selectedIcon,
                                  label: Text(destination.label),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  enabled: visible,
                ),
              ),
            ),
          if (showRail)
            SizedBox(
              width: 1 - progress,
              child: const VerticalDivider(thickness: 1, width: 1),
            ),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeLeft: true,
              removeRight: true,
              removeBottom: true,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  safePadding.left * (1 - progress),
                  0,
                  safePadding.right * (1 - progress),
                  safePadding.bottom * (1 - progress),
                ),
                child: Column(
                  children: [
                    Expanded(child: child),
                    if (miniPlayer != null)
                      _protectNavigation(
                        ClipRect(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            heightFactor: 1 - progress,
                            child: miniPlayer,
                          ),
                        ),
                        enabled: visible,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    } else if (layoutVisible) {
      content = Builder(
        builder: (context) {
          final mediaQuery = MediaQuery.of(context);
          return MediaQuery(
            data: mediaQuery.copyWith(
              viewPadding: mediaQuery.viewPadding.copyWith(
                bottom: mediaQuery.padding.bottom,
              ),
            ),
            child: child,
          );
        },
      );
    }

    return Scaffold(
      extendBody: !isLandscape,
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(top: showOffline ? 30 : 0),
            child: content,
          ),
          if (showOffline)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _protectNavigation(_offlineBanner(context, ref)),
            ),
        ],
      ),
      bottomNavigationBar: layoutVisible && !isLandscape
          ? _protectNavigation(
              ClipRect(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  heightFactor: 1 - progress,
                  child: AppBottomDock(
                    selectedIndex: controller.selectedIndex,
                    onDestinationSelected: selectTab,
                    destinations: destinations,
                    miniPlayer: miniPlayer,
                  ),
                ),
              ),
              enabled: visible,
            )
          : null,
    );
  }

  Widget _protectNavigation(Widget navigation, {bool enabled = true}) {
    final popup = controller.popupRoute;
    final excluded = popup != null || !enabled;
    return Stack(
      children: [
        IgnorePointer(
          ignoring: !enabled,
          child: ExcludeFocus(
            excluding: excluded,
            child: ExcludeSemantics(excluding: excluded, child: navigation),
          ),
        ),
        if (popup != null)
          Positioned.fill(
            child: AnimatedModalBarrier(
              color: popup.animation!.drive(
                ColorTween(
                  begin: Colors.transparent,
                  end: popup.barrierColor ?? Colors.transparent,
                ),
              ),
              dismissible: popup.barrierDismissible,
              onDismiss: () {
                if (popup.isCurrent) controller.navigator?.maybePop();
              },
              semanticsLabel: popup.barrierLabel,
            ),
          ),
      ],
    );
  }

  Widget _offlineBanner(BuildContext context, WidgetRef ref) => Container(
    padding: EdgeInsets.fromLTRB(
      12,
      MediaQuery.paddingOf(context).top + 4,
      12,
      4,
    ),
    color: Colors.orange.shade800,
    child: Row(
      children: [
        const Icon(Icons.cloud_off, size: 14, color: Colors.white),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            S.of(context).offlineModeMessage,
            style: const TextStyle(fontSize: 11, color: Colors.white),
          ),
        ),
        TextButton(
          onPressed: () => ref.read(authProvider.notifier).retryConnection(),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            S.of(context).retry,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    ),
  );
}
