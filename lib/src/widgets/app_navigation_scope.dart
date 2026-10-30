import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

const appImmersiveRouteSettings = RouteSettings(name: 'app-immersive');
const appAudioTabIndex = 0;
const appVideoTabIndex = 2;
const appTabCount = 4;

class AppNavigationController extends NavigatorObserver with ChangeNotifier {
  AppNavigationController()
    : _tabNavigatorKeys = List.generate(
        appTabCount,
        (_) => GlobalKey<NavigatorState>(),
      ),
      _tabObservers = List.generate(
        appTabCount,
        (_) => _AppTabNavigatorObserver(),
      ) {
    for (final observer in _tabObservers) {
      observer.controller = this;
    }
  }

  final List<Route<dynamic>> _routes = [];
  final Map<
    PopupRoute<dynamic>,
    ({
      NavigatorState navigator,
      NavigatorState host,
      PageRoute<dynamic>? page,
      ValueListenable<bool> coveredByPage,
    })
  >
  _sheetRoutes = {};
  final Set<Route<dynamic>> _fullscreenRoutes = {};
  final Map<Route<dynamic>, Animation<double>> _fullscreenTransitions = {};
  final List<GlobalKey<NavigatorState>> _tabNavigatorKeys;
  final List<_AppTabNavigatorObserver> _tabObservers;
  int _selectedIndex = 0;
  bool _navigationVisible = true;
  bool _playerLaunchPreviewActive = false;
  Animation<double>? _fullscreenTransition;
  PopupRoute<dynamic>? _popupRoute;
  PageRoute<dynamic>? _outgoing;

  int get selectedIndex => _selectedIndex;
  bool get navigationVisible => _navigationVisible;
  bool get playerLaunchPreviewActive => _playerLaunchPreviewActive;
  Animation<double>? get fullscreenTransition => _fullscreenTransition;
  PopupRoute<dynamic>? get popupRoute => _popupRoute ?? sheetRoutes.lastOrNull;
  Iterable<PopupRoute<dynamic>> get popupRoutes => {
    ..._routes.whereType<PopupRoute<dynamic>>(),
    if (!rootRouteCoversTabs) ..._tabObservers[_selectedIndex].popupRoutes,
    ...sheetRoutes,
  };
  bool get rootRouteCoversTabs {
    final page =
        _outgoing ?? _routes.whereType<PageRoute<dynamic>>().lastOrNull;
    return page != null && !page.isFirst;
  }

  GlobalKey<NavigatorState> tabNavigatorKey(int index) =>
      _tabNavigatorKeys[index];

  NavigatorState? tabNavigator(int index) =>
      _tabNavigatorKeys[index].currentState;

  NavigatorObserver tabObserver(int index) => _tabObservers[index];
  Iterable<PopupRoute<dynamic>> get sheetRoutes {
    final visible = <PopupRoute<dynamic>>[];
    for (final entry in _sheetRoutes.entries) {
      final navigator = entry.value.navigator;
      final host = entry.value.host;
      final rootNavigator = identical(host, this.navigator);
      if (!rootNavigator &&
          (rootRouteCoversTabs ||
              !identical(host, tabNavigator(_selectedIndex)))) {
        continue;
      }
      if (!identical(entry.value.page, _currentPageFor(host))) continue;
      if (entry.value.coveredByPage.value) {
        // A page also covers earlier sheets in the same Navigator.
        visible.removeWhere(
          (route) => identical(_sheetRoutes[route]?.navigator, navigator),
        );
      } else {
        visible.add(entry.key);
      }
    }
    return visible;
  }

  void registerSheet(
    PopupRoute<dynamic> route,
    NavigatorState navigator,
    ValueListenable<bool> coveredByPage,
  ) {
    final host = _sheetHostFor(navigator);
    _sheetRoutes[route] = (
      navigator: navigator,
      host: host,
      page: _currentPageFor(host),
      coveredByPage: coveredByPage,
    );
    coveredByPage.addListener(_sheetCoverageChanged);
    _refresh(forceNotify: true);
  }

  void unregisterSheet(PopupRoute<dynamic> route) {
    final sheet = _sheetRoutes.remove(route);
    if (sheet != null) {
      sheet.coveredByPage.removeListener(_sheetCoverageChanged);
      _refresh(forceNotify: true);
    }
  }

  void _sheetCoverageChanged() => _refresh(forceNotify: true);

  NavigatorState _sheetHostFor(NavigatorState navigator) {
    var host = navigator;
    while (!identical(host, this.navigator) &&
        !_tabNavigatorKeys.any((key) => identical(key.currentState, host))) {
      final parent = host.context.findAncestorStateOfType<NavigatorState>();
      if (parent == null) break;
      host = parent;
    }
    return host;
  }

  PageRoute<dynamic>? _currentPageFor(NavigatorState navigator) {
    if (identical(navigator, this.navigator)) {
      return _routes.whereType<PageRoute<dynamic>>().lastOrNull;
    }
    for (var index = 0; index < _tabNavigatorKeys.length; index++) {
      if (identical(navigator, tabNavigator(index))) {
        return _tabObservers[index].sheetPage;
      }
    }
    return null;
  }

  @override
  void dispose() {
    for (final sheet in _sheetRoutes.values) {
      sheet.coveredByPage.removeListener(_sheetCoverageChanged);
    }
    _sheetRoutes.clear();
    super.dispose();
  }

  void selectTab(int index) {
    if (index == _selectedIndex) return;
    _selectedIndex = index;
    _refresh(forceNotify: true);
  }

  void setFullscreen(
    Route<dynamic> route,
    bool fullscreen, {
    Animation<double>? transition,
  }) {
    if (fullscreen) {
      _fullscreenRoutes.add(route);
    } else {
      _fullscreenRoutes.remove(route);
    }
    if (transition == null) {
      _fullscreenTransitions.remove(route);
    } else {
      _fullscreenTransitions[route] = transition;
    }
    _refresh();
  }

  void setPlayerLaunchPreview(bool active) {
    if (_playerLaunchPreviewActive == active) return;
    _playerLaunchPreviewActive = active;
    _refresh(forceNotify: true);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute<dynamic>) _outgoing = null;
    _routes.add(route);
    _refresh(
      forceNotify: route is PageRoute<dynamic> && _sheetRoutes.isNotEmpty,
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute<dynamic>) {
      _routes.remove(route);
      _outgoing ??= route;
    }
    // Popup barriers stay registered until their closing animation completes.
    if (route is TransitionRoute<dynamic>) {
      unawaited(route.completed.whenComplete(() => _remove(route)));
    } else {
      _remove(route);
    }
    _refresh(
      forceNotify: route is PageRoute<dynamic> && _sheetRoutes.isNotEmpty,
    );
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _outgoing = null;
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    _routes.remove(oldRoute);
    if (oldRoute != null) _forgetRoute(oldRoute);
    if (newRoute != null) {
      if (index < 0) {
        _routes.add(newRoute);
      } else {
        _routes.insert(index, newRoute);
      }
    }
    _refresh(forceNotify: _sheetRoutes.isNotEmpty);
  }

  void _remove(Route<dynamic> route) {
    _routes.remove(route);
    _forgetRoute(route);
    if (identical(_outgoing, route)) _outgoing = null;
    _refresh(
      forceNotify: route is PageRoute<dynamic> && _sheetRoutes.isNotEmpty,
    );
  }

  void _forgetRoute(Route<dynamic> route) {
    _fullscreenRoutes.remove(route);
    _fullscreenTransitions.remove(route);
  }

  void _refresh({bool forceNotify = false}) {
    final rootPage =
        _outgoing ?? _routes.whereType<PageRoute<dynamic>>().lastOrNull;
    final page = rootRouteCoversTabs
        ? rootPage
        : _tabObservers[_selectedIndex].currentPage ?? rootPage;
    final visible =
        !_playerLaunchPreviewActive &&
        page?.settings.name != appImmersiveRouteSettings.name &&
        !_fullscreenRoutes.contains(page);
    final transition = page == null ? null : _fullscreenTransitions[page];
    final lastRoute = _routes.lastOrNull;
    final rootPopup = lastRoute is PopupRoute<dynamic> ? lastRoute : null;
    final popup =
        rootPopup ??
        (rootRouteCoversTabs ? null : _tabObservers[_selectedIndex].popupRoute);
    if (_navigationVisible == visible &&
        identical(_fullscreenTransition, transition) &&
        _popupRoute == popup &&
        !forceNotify) {
      return;
    }
    _navigationVisible = visible;
    _fullscreenTransition = transition;
    _popupRoute = popup;
    if (hasListeners) notifyListeners();
  }
}

class _AppTabNavigatorObserver extends NavigatorObserver {
  late AppNavigationController controller;

  final List<Route<dynamic>> _routes = [];
  PageRoute<dynamic>? _outgoing;

  PageRoute<dynamic>? get currentPage =>
      _outgoing ?? _routes.whereType<PageRoute<dynamic>>().lastOrNull;

  PageRoute<dynamic>? get sheetPage =>
      _routes.whereType<PageRoute<dynamic>>().lastOrNull;

  PopupRoute<dynamic>? get popupRoute {
    final route = _routes.lastOrNull;
    return route is PopupRoute<dynamic> ? route : null;
  }

  Iterable<PopupRoute<dynamic>> get popupRoutes =>
      _routes.whereType<PopupRoute<dynamic>>();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute<dynamic>) _outgoing = null;
    _routes.add(route);
    controller._refresh(
      forceNotify:
          route is PageRoute<dynamic> && controller._sheetRoutes.isNotEmpty,
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute<dynamic>) {
      _routes.remove(route);
      _outgoing ??= route;
    }
    if (route is TransitionRoute<dynamic>) {
      unawaited(route.completed.whenComplete(() => _remove(route)));
    } else {
      _remove(route);
    }
    controller._refresh(
      forceNotify:
          route is PageRoute<dynamic> && controller._sheetRoutes.isNotEmpty,
    );
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _outgoing = null;
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    _routes.remove(oldRoute);
    if (oldRoute != null) controller._forgetRoute(oldRoute);
    if (newRoute != null) {
      if (index < 0) {
        _routes.add(newRoute);
      } else {
        _routes.insert(index, newRoute);
      }
    }
    controller._refresh(forceNotify: controller._sheetRoutes.isNotEmpty);
  }

  void _remove(Route<dynamic> route) {
    _routes.remove(route);
    controller._forgetRoute(route);
    if (identical(_outgoing, route)) _outgoing = null;
    controller._refresh(
      forceNotify:
          route is PageRoute<dynamic> && controller._sheetRoutes.isNotEmpty,
    );
  }
}

class AppNavigationScope extends InheritedNotifier<AppNavigationController> {
  const AppNavigationScope({
    super.key,
    required AppNavigationController controller,
    required this.mediaQuery,
    required super.child,
  }) : super(notifier: controller);

  final MediaQueryData mediaQuery;

  @override
  bool updateShouldNotify(AppNavigationScope oldWidget) =>
      super.updateShouldNotify(oldWidget) ||
      mediaQuery.padding != oldWidget.mediaQuery.padding ||
      mediaQuery.viewPadding != oldWidget.mediaQuery.viewPadding;

  static AppNavigationController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppNavigationScope>()
      ?.notifier;

  static AppNavigationController of(BuildContext context) => maybeOf(context)!;

  static NavigatorState navigatorOf(BuildContext context) =>
      maybeOf(context)?.navigator ?? Navigator.of(context);
}
