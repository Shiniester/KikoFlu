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

class AppNavigationShell extends StatefulWidget {
  const AppNavigationShell({
    super.key,
    required this.controller,
    required this.child,
  });

  final AppNavigationController controller;
  final Widget child;

  @override
  State<AppNavigationShell> createState() => _AppNavigationShellState();
}

class _AppNavigationShellState extends State<AppNavigationShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _navigationMotion;
  late bool _navigationVisible;
  late bool _playerLaunchPreviewActive;
  bool _animateNavigation = false;
  bool _reduceMotion = false;

  AppNavigationController get controller => widget.controller;
  Widget get child => widget.child;

  @override
  void initState() {
    super.initState();
    _navigationVisible = controller.navigationVisible;
    _playerLaunchPreviewActive = controller.playerLaunchPreviewActive;
    _navigationMotion = AnimationController(
      vsync: this,
      value: _navigationVisible ? 0 : 1,
      duration: const Duration(milliseconds: 240),
    );
    controller.addListener(_syncNavigation);
  }

  @override
  void didUpdateWidget(covariant AppNavigationShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      oldWidget.controller.removeListener(_syncNavigation);
      controller.addListener(_syncNavigation);
      _playerLaunchPreviewActive = controller.playerLaunchPreviewActive;
      _syncNavigation();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion && !_reduceMotion) {
      _navigationMotion.value = controller.navigationVisible ? 0 : 1;
    }
    _reduceMotion = reduceMotion;
  }

  void _syncNavigation() {
    final visible = controller.navigationVisible;
    final previewActive = controller.playerLaunchPreviewActive;
    final handoffCompleted =
        _playerLaunchPreviewActive &&
        !previewActive &&
        !visible &&
        controller.fullscreenTransition == null;
    _playerLaunchPreviewActive = previewActive;
    if (handoffCompleted) {
      _navigationVisible = visible;
      _animateNavigation = true;
      _navigationMotion.value = 1;
      return;
    }
    if (_navigationVisible == visible) return;
    _navigationVisible = visible;
    if (!visible) {
      _animateNavigation =
          previewActive || controller.fullscreenTransition == null;
    }
    final target = visible ? 0.0 : 1.0;
    if (_reduceMotion || !_animateNavigation) {
      _navigationMotion.value = target;
    } else {
      _navigationMotion.animateTo(target, curve: Curves.easeOutCubic);
    }
  }

  @override
  void dispose() {
    controller.removeListener(_syncNavigation);
    _navigationMotion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Overlay.wrap(
    child: AppNavigationScope(
      controller: controller,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => AnimatedBuilder(
          animation: Listenable.merge([
            _navigationMotion,
            controller.fullscreenTransition,
          ]),
          builder: (context, _) =>
              Consumer(builder: (context, ref, _) => _buildShell(context, ref)),
        ),
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
    final miniPlayer = ref
        .watch(currentTrackProvider)
        .when<Widget?>(
          data: (track) => track == null ? null : const MiniPlayer(),
          loading: () => null,
          error: (_, __) => null,
        );
    void selectTab(int index) {
      if (index == controller.selectedIndex) return;
      controller.selectTab(index);
      if (index == 3) {
        ref.read(settingsCacheRefreshTriggerProvider.notifier).state++;
      }
    }

    final explicitTransition = !_animateNavigation && transition != null;
    return _buildShellFrame(
      context,
      isLandscape: isLandscape,
      offline: offline,
      miniPlayer: miniPlayer,
      destinations: destinations,
      selectTab: selectTab,
      ref: ref,
      progress: explicitTransition ? transition.value : _navigationMotion.value,
      explicitTransition: explicitTransition,
      safePadding: MediaQuery.paddingOf(context),
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
    required bool explicitTransition,
    required EdgeInsets safePadding,
  }) {
    final visible = controller.navigationVisible;
    final layoutVisible =
        visible ||
        (isLandscape && controller.playerLaunchPreviewActive) ||
        (explicitTransition && progress < 1);
    final navigationOnstage =
        visible || progress < 1 || controller.playerLaunchPreviewActive;
    final showOffline = offline && visible;
    // An immersive route keeps its viewport while the Dock slides out.
    Widget content = MediaQuery(data: MediaQuery.of(context), child: child);
    final rail = isLandscape && navigationOnstage
        ? _protectNavigation(
            _buildNavigationRail(context, destinations, selectTab),
            enabled: visible,
          )
        : null;
    final playback = miniPlayer == null
        ? null
        : _protectNavigation(
            ClipRect(
              child: explicitTransition
                  ? Align(
                      alignment: Alignment.bottomCenter,
                      heightFactor: 1 - progress,
                      child: miniPlayer,
                    )
                  : FractionalTranslation(
                      translation: Offset(0, progress),
                      child: miniPlayer,
                    ),
            ),
            enabled: visible,
          );
    if (layoutVisible && isLandscape) {
      final showRail = !explicitTransition || progress < 1;
      final paddingFactor = explicitTransition ? 1 - progress : 1.0;
      content = Row(
        children: [
          if (showRail)
            ClipRect(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: explicitTransition ? 1 - progress : 1,
                child: FractionalTranslation(
                  translation: Offset(explicitTransition ? 0 : -progress, 0),
                  child: rail,
                ),
              ),
            ),
          if (showRail)
            SizedBox(
              width: explicitTransition ? 1 - progress : 1,
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
                  safePadding.left * paddingFactor,
                  0,
                  safePadding.right * paddingFactor,
                  safePadding.bottom * paddingFactor,
                ),
                child: Column(
                  children: [
                    Expanded(child: child),
                    if (playback != null) playback,
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
    final dock = AppBottomDock(
      selectedIndex: controller.selectedIndex,
      onDestinationSelected: selectTab,
      destinations: destinations,
      miniPlayer: miniPlayer,
    );

    return Scaffold(
      extendBody: !isLandscape,
      resizeToAvoidBottomInset: visible,
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(top: showOffline ? 30 : 0),
            child: content,
          ),
          if (!layoutVisible && rail != null)
            Positioned.fill(
              child: Row(
                children: [
                  FractionalTranslation(
                    translation: Offset(-progress, 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        rail,
                        const VerticalDivider(thickness: 1, width: 1),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        safePadding.left,
                        0,
                        safePadding.right,
                        safePadding.bottom,
                      ),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: playback,
                      ),
                    ),
                  ),
                ],
              ),
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
      bottomNavigationBar: navigationOnstage && !isLandscape
          ? _protectNavigation(
              ClipRect(
                child: explicitTransition
                    ? Align(
                        alignment: Alignment.bottomCenter,
                        heightFactor: 1 - progress,
                        child: dock,
                      )
                    : FractionalTranslation(
                        translation: Offset(0, progress),
                        child: dock,
                      ),
              ),
              enabled: visible,
            )
          : null,
    );
  }

  Widget _buildNavigationRail(
    BuildContext context,
    List<NavigationDestination> destinations,
    ValueChanged<int> selectTab,
  ) => SafeArea(
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
  );

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
