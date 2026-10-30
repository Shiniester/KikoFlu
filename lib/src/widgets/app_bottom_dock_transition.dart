import 'package:flutter/material.dart';

Future<void> pushWorkDetailRoute(
  BuildContext context, {
  required WidgetBuilder builder,
  NavigatorState? navigator,
}) => pushBottomDockRoute(context, builder: builder, navigator: navigator);

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
  var route = _BottomDockPageRoute(builder: builder);
  await (navigator ?? Navigator.of(context)).push<void>(route);
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
