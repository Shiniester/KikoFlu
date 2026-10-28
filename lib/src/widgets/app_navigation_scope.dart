import 'dart:async';

import 'package:flutter/material.dart';

const appImmersiveRouteSettings = RouteSettings(name: 'app-immersive');

class AppNavigationController extends NavigatorObserver with ChangeNotifier {
  final List<Route<dynamic>> _routes = [];
  final Set<Route<dynamic>> _fullscreenRoutes = {};
  final Map<Route<dynamic>, Animation<double>> _fullscreenTransitions = {};
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
  PopupRoute<dynamic>? get popupRoute => _popupRoute;

  void selectTab(int index) {
    if (index == _selectedIndex) return;
    _selectedIndex = index;
    navigator?.popUntil((route) => route.isFirst);
    notifyListeners();
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
    _refresh();
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
    _refresh();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _outgoing = null;
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    _routes.remove(oldRoute);
    _fullscreenRoutes.remove(oldRoute);
    _fullscreenTransitions.remove(oldRoute);
    if (newRoute != null) {
      if (index < 0) {
        _routes.add(newRoute);
      } else {
        _routes.insert(index, newRoute);
      }
    }
    _refresh();
  }

  void _remove(Route<dynamic> route) {
    _routes.remove(route);
    _fullscreenRoutes.remove(route);
    _fullscreenTransitions.remove(route);
    if (identical(_outgoing, route)) _outgoing = null;
    _refresh();
  }

  void _refresh({bool forceNotify = false}) {
    final page =
        _outgoing ?? _routes.whereType<PageRoute<dynamic>>().lastOrNull;
    final visible =
        !_playerLaunchPreviewActive &&
        page?.settings.name != appImmersiveRouteSettings.name &&
        !_fullscreenRoutes.contains(page);
    final transition = page == null ? null : _fullscreenTransitions[page];
    final lastRoute = _routes.lastOrNull;
    final popup = lastRoute is PopupRoute<dynamic> ? lastRoute : null;
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

class AppNavigationScope extends InheritedNotifier<AppNavigationController> {
  const AppNavigationScope({
    super.key,
    required AppNavigationController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppNavigationController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppNavigationScope>()
      ?.notifier;

  static AppNavigationController of(BuildContext context) => maybeOf(context)!;

  static NavigatorState navigatorOf(BuildContext context) =>
      maybeOf(context)?.navigator ?? Navigator.of(context);
}
