import 'package:flutter/material.dart';

import 'app_navigation_scope.dart';

Future<void> pushWorkDetailRoute(
  BuildContext context, {
  required WidgetBuilder builder,
  NavigatorState? navigator,
}) => pushBottomDockRoute(context, builder: builder, navigator: navigator);

Future<void> pushAudioPlayerHandoffRoute(
  BuildContext context, {
  required WidgetBuilder builder,
}) async {
  final navigation = AppNavigationScope.maybeOf(context);
  final playerRoute = ModalRoute.of(context);
  final rootNavigator = navigation?.navigator;
  if (navigation == null ||
      rootNavigator == null ||
      playerRoute == null ||
      !identical(navigation.audioPlayerRoute, playerRoute)) {
    await pushBottomDockRoute(context, builder: builder);
    return;
  }
  if (!playerRoute.isCurrent) return;
  navigation.selectTab(appAudioTabIndex);
  var audioNavigator = navigation.tabNavigator(appAudioTabIndex);
  if (audioNavigator == null) {
    await WidgetsBinding.instance.endOfFrame;
    if (!context.mounted) return;
    audioNavigator = navigation.tabNavigator(appAudioTabIndex);
  }
  if (!playerRoute.isCurrent ||
      !identical(navigation.audioPlayerRoute, playerRoute)) {
    return;
  }
  if (audioNavigator == null) {
    rootNavigator.pop();
    await _pushBottomDockPageRoute(
      rootNavigator,
      _BottomDockPageRoute(builder: builder),
    );
    return;
  }
  final route = pushBottomDockRoute(
    context,
    navigator: audioNavigator,
    builder: builder,
  );
  rootNavigator.popUntil((route) => route.isFirst);
  await route;
}

/// Replaces an automatically completed detail without adding a return step.
Future<void> replaceWorkDetailRoute(
  BuildContext context, {
  required WidgetBuilder builder,
}) async {
  if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) return;
  final previous = ModalRoute.of(context);
  final route = _BottomDockPageRoute(builder: builder, replaceCurrent: true);
  if (previous is _BottomDockPageRoute) previous.replacement = route;
  await Navigator.of(context).pushReplacement<void, void>(route);
  await route.completed;
}

Future<void> pushBottomDockRoute(
  BuildContext context, {
  required WidgetBuilder builder,
  NavigatorState? navigator,
}) async {
  if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) return;
  await _pushBottomDockPageRoute(
    navigator ?? Navigator.of(context),
    _BottomDockPageRoute(builder: builder),
  );
}

Future<void> _pushBottomDockPageRoute(
  NavigatorState navigator,
  _BottomDockPageRoute initialRoute,
) async {
  var route = initialRoute;
  await navigator.push<void>(route);
  while (true) {
    await route.completed;
    final replacement = route.replacement;
    if (replacement == null) return;
    route = replacement;
    await route.popped;
  }
}

class _BottomDockPageRoute extends MaterialPageRoute<void> {
  _BottomDockPageRoute({required super.builder, this.replaceCurrent = false});

  final bool replaceCurrent;
  _BottomDockPageRoute? replacement;

  @override
  Duration get transitionDuration =>
      replaceCurrent ? Duration.zero : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration => super.transitionDuration;
}
