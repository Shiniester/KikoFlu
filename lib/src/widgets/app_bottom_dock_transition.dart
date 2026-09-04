import 'package:flutter/material.dart';

const _miniPlayerHeroTag = 'app-bottom-dock-mini-player';
const _appTabBarHeroTag = 'app-bottom-dock-tab-bar';

enum AppBottomDockRole { source, workDetailsTarget }

/// Keeps the source-side Bottom Dock heroes available for the complete
/// lifetime of a pushed Work Details Screen route.
class AppBottomDockTransitionScope extends StatefulWidget {
  const AppBottomDockTransitionScope({super.key, required this.child});

  final Widget child;

  @override
  State<AppBottomDockTransitionScope> createState() =>
      _AppBottomDockTransitionScopeState();

  static _AppBottomDockTransitionScopeState? _maybeStateOf(
    BuildContext context,
  ) {
    return context
        .getInheritedWidgetOfExactType<_AppBottomDockTransitionHost>()
        ?.state;
  }

  static bool _sourceHeroesEnabledOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<_AppBottomDockTransitionHost>()
            ?.sourceHeroesEnabled ??
        false;
  }
}

class _AppBottomDockTransitionScopeState
    extends State<AppBottomDockTransitionScope> {
  int _activeRoutes = 0;

  _AppBottomDockTransitionLease arm() {
    setState(() => _activeRoutes++);
    return _AppBottomDockTransitionLease(this);
  }

  void _release() {
    if (!mounted || _activeRoutes == 0) return;
    setState(() => _activeRoutes--);
  }

  @override
  Widget build(BuildContext context) {
    return _AppBottomDockTransitionHost(
      state: this,
      sourceHeroesEnabled: _activeRoutes > 0,
      child: widget.child,
    );
  }
}

class _AppBottomDockTransitionLease {
  _AppBottomDockTransitionLease(this._owner);

  _AppBottomDockTransitionScopeState? _owner;

  void release() {
    _owner?._release();
    _owner = null;
  }
}

class _AppBottomDockTransitionHost extends InheritedWidget {
  const _AppBottomDockTransitionHost({
    required this.state,
    required this.sourceHeroesEnabled,
    required super.child,
  });

  final _AppBottomDockTransitionScopeState state;
  final bool sourceHeroesEnabled;

  @override
  bool updateShouldNotify(_AppBottomDockTransitionHost oldWidget) {
    return sourceHeroesEnabled != oldWidget.sourceHeroesEnabled;
  }
}

/// Pushes a Work Details Screen while preserving the source Bottom Dock until
/// the route has completely left the Navigator again.
Future<void> pushWorkDetailRoute(
  BuildContext context, {
  required WidgetBuilder builder,
}) async {
  final sourceScope = AppBottomDockTransitionScope._maybeStateOf(context);
  final lease = sourceScope?.arm();
  if (lease != null) {
    await WidgetsBinding.instance.endOfFrame;
  }
  if (!context.mounted) {
    lease?.release();
    return;
  }

  final route = MaterialPageRoute<void>(builder: builder);
  try {
    await Navigator.of(context).push<void>(route);
    await route.completed;
  } finally {
    lease?.release();
  }
}

class AppBottomDockMiniPlayerHero extends StatelessWidget {
  const AppBottomDockMiniPlayerHero.source({super.key, required this.child})
    : _role = AppBottomDockRole.source;

  const AppBottomDockMiniPlayerHero.target({super.key, required this.child})
    : _role = AppBottomDockRole.workDetailsTarget;

  final Widget child;
  final AppBottomDockRole _role;

  static bool artworkHeroEnabledOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<_DockArtworkHeroMode>()
            ?.enabled ??
        true;
  }

  @override
  Widget build(BuildContext context) {
    final enabled =
        _role == AppBottomDockRole.workDetailsTarget ||
        AppBottomDockTransitionScope._sourceHeroesEnabledOf(context);
    return _AppBottomDockHero(
      tag: _miniPlayerHeroTag,
      enabled: enabled,
      flightChild: child,
      suppressDescendantHeroes: true,
      child: child,
    );
  }
}

class AppBottomDockTabBarHero extends StatelessWidget {
  const AppBottomDockTabBarHero.source({super.key, required this.child})
    : height = null;

  const AppBottomDockTabBarHero.offstageTarget({
    super.key,
    required this.height,
  }) : child = null;

  final Widget? child;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final tabBar = child;
    if (tabBar != null) {
      return _AppBottomDockHero(
        tag: _appTabBarHeroTag,
        enabled: AppBottomDockTransitionScope._sourceHeroesEnabledOf(context),
        flightChild: tabBar,
        child: tabBar,
      );
    }

    return IgnorePointer(
      child: ExcludeSemantics(
        child: FractionalTranslation(
          translation: const Offset(0, 1),
          child: _AppBottomDockHero(
            tag: _appTabBarHeroTag,
            enabled: true,
            child: SizedBox(width: double.infinity, height: height),
          ),
        ),
      ),
    );
  }
}

class _AppBottomDockHero extends StatelessWidget {
  const _AppBottomDockHero({
    required this.tag,
    required this.enabled,
    required this.child,
    this.flightChild,
    this.suppressDescendantHeroes = false,
  });

  final Object tag;
  final bool enabled;
  final Widget child;
  final Widget? flightChild;
  final bool suppressDescendantHeroes;

  @override
  Widget build(BuildContext context) {
    if (!enabled || MediaQuery.disableAnimationsOf(context)) return child;
    return Hero(
      tag: tag,
      transitionOnUserGestures: true,
      curve: Curves.linear,
      reverseCurve: Curves.linear,
      createRectTween: (begin, end) => RectTween(begin: begin, end: end),
      flightShuttleBuilder: _buildAppBottomDockFlight,
      child: _AppBottomDockHeroPayload(
        flightChild: flightChild,
        suppressDescendantHeroes: suppressDescendantHeroes,
        child: suppressDescendantHeroes
            ? _DockArtworkHeroMode(enabled: false, child: child)
            : child,
      ),
    );
  }
}

class _AppBottomDockHeroPayload extends StatelessWidget {
  const _AppBottomDockHeroPayload({
    required this.child,
    required this.flightChild,
    required this.suppressDescendantHeroes,
  });

  final Widget child;
  final Widget? flightChild;
  final bool suppressDescendantHeroes;

  @override
  Widget build(BuildContext context) => child;
}

Widget _buildAppBottomDockFlight(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final fromHero = fromHeroContext.widget as Hero;
  final toHero = toHeroContext.widget as Hero;
  final from = fromHero.child as _AppBottomDockHeroPayload;
  final to = toHero.child as _AppBottomDockHeroPayload;
  final preferred = direction == HeroFlightDirection.push ? to : from;
  final fallback = direction == HeroFlightDirection.push ? from : to;
  final child =
      preferred.flightChild ?? fallback.flightChild ?? preferred.child;
  final flightChild =
      preferred.suppressDescendantHeroes || fallback.suppressDescendantHeroes
      ? _DockArtworkHeroMode(enabled: false, child: child)
      : child;
  return IgnorePointer(
    child: Material(
      type: MaterialType.transparency,
      child: HeroMode(enabled: false, child: flightChild),
    ),
  );
}

class _DockArtworkHeroMode extends InheritedWidget {
  const _DockArtworkHeroMode({required this.enabled, required super.child});

  final bool enabled;

  @override
  bool updateShouldNotify(_DockArtworkHeroMode oldWidget) {
    return enabled != oldWidget.enabled;
  }
}
