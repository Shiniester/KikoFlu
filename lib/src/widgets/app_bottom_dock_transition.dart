import 'package:flutter/material.dart';

const _miniPlayerHeroTag = 'app-bottom-dock-mini-player';
const _appTabBarHeroTag = 'app-bottom-dock-tab-bar';
const double appBottomDockNavigationBarHeight = 58;

@visibleForTesting
const appBottomDockMiniPlayerFlightRootKey = ValueKey<String>(
  'app-bottom-dock-mini-player-flight-root',
);

@visibleForTesting
const appBottomDockTabBarFlightRootKey = ValueKey<String>(
  'app-bottom-dock-tab-bar-flight-root',
);

enum _AppBottomDockHeroPart { miniPlayer, tabBar }

enum AppBottomDockRole { source, workDetailsTarget }

/// Keeps the source-side Bottom Dock heroes available for the complete
/// lifetime of a pushed Work Details Screen route.
class AppBottomDockTransitionScope extends StatefulWidget {
  const AppBottomDockTransitionScope({
    super.key,
    required this.child,
    this.sourceHasAppTabBar = true,
  });

  final Widget child;
  final bool sourceHasAppTabBar;

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

  static double? handoffBottomInsetOf(BuildContext context) {
    return _AppBottomDockHandoffMetrics.handoffBottomInsetOf(context);
  }

  static double bottomInsetOf(BuildContext context) {
    return _AppBottomDockHandoffMetrics.bottomInsetOf(context) ??
        MediaQuery.viewPaddingOf(context).bottom;
  }

  static bool sourceHasAppTabBarOf(BuildContext context) {
    return _AppBottomDockHandoffMetrics.sourceHasAppTabBarOf(context) ?? false;
  }

  static Widget withHandoffBottomInset(
    BuildContext context, {
    required double bottomInset,
    required Widget child,
  }) {
    final mediaQuery = MediaQuery.of(context);
    return MediaQuery(
      data: mediaQuery.copyWith(
        viewPadding: mediaQuery.viewPadding.copyWith(bottom: bottomInset),
      ),
      child: child,
    );
  }

  static Widget _withHandoffMetrics({
    required double bottomInset,
    required bool frozen,
    required bool sourceHasAppTabBar,
    required Widget child,
  }) {
    return _AppBottomDockHandoffMetrics(
      bottomInset: bottomInset,
      frozen: frozen,
      sourceHasAppTabBar: sourceHasAppTabBar,
      child: child,
    );
  }
}

class _AppBottomDockTransitionScopeState
    extends State<AppBottomDockTransitionScope> {
  final List<_AppBottomDockHandoff> _handoffs = [];

  bool get sourceHasAppTabBar => widget.sourceHasAppTabBar;

  _AppBottomDockTransitionLease arm(double bottomInset) {
    final handoff = _AppBottomDockHandoff(bottomInset);
    setState(() => _handoffs.add(handoff));
    return _AppBottomDockTransitionLease(this, handoff);
  }

  void _release(_AppBottomDockHandoff handoff) {
    if (!mounted || !_handoffs.contains(handoff)) return;
    setState(() => _handoffs.remove(handoff));
  }

  @override
  Widget build(BuildContext context) {
    final inheritedMetrics = _AppBottomDockHandoffMetrics._maybeOf(context);
    final inheritedHandoffBottomInset = inheritedMetrics?.frozen == true
        ? inheritedMetrics!.bottomInset
        : null;
    final hasLocalHandoff = _handoffs.isNotEmpty;
    final frozen = hasLocalHandoff || inheritedHandoffBottomInset != null;
    final bottomInset = hasLocalHandoff
        ? _handoffs.last.bottomInset
        : inheritedHandoffBottomInset ??
              MediaQuery.viewPaddingOf(context).bottom;
    final host = _AppBottomDockTransitionHost(
      state: this,
      sourceHeroesEnabled: _handoffs.isNotEmpty,
      child: widget.child,
    );
    return AppBottomDockTransitionScope._withHandoffMetrics(
      bottomInset: bottomInset,
      frozen: frozen,
      sourceHasAppTabBar: hasLocalHandoff
          ? widget.sourceHasAppTabBar
          : inheritedHandoffBottomInset != null
          ? inheritedMetrics!.sourceHasAppTabBar
          : widget.sourceHasAppTabBar,
      child: host,
    );
  }
}

class _AppBottomDockHandoff {
  const _AppBottomDockHandoff(this.bottomInset);

  final double bottomInset;
}

class _AppBottomDockTransitionLease {
  _AppBottomDockTransitionLease(this._owner, this._handoff);

  _AppBottomDockTransitionScopeState? _owner;
  _AppBottomDockHandoff? _handoff;

  void release() {
    final owner = _owner;
    final handoff = _handoff;
    if (owner != null && handoff != null) owner._release(handoff);
    _owner = null;
    _handoff = null;
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

class _AppBottomDockHandoffMetrics extends InheritedWidget {
  const _AppBottomDockHandoffMetrics({
    required this.bottomInset,
    required this.frozen,
    required this.sourceHasAppTabBar,
    required super.child,
  });

  final double bottomInset;
  final bool frozen;
  final bool sourceHasAppTabBar;

  static _AppBottomDockHandoffMetrics? _maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_AppBottomDockHandoffMetrics>();
  }

  static double? bottomInsetOf(BuildContext context) {
    return _maybeOf(context)?.bottomInset;
  }

  static double? handoffBottomInsetOf(BuildContext context) {
    final metrics = _maybeOf(context);
    if (metrics == null || !metrics.frozen) return null;
    return metrics.bottomInset;
  }

  static bool? sourceHasAppTabBarOf(BuildContext context) {
    return _maybeOf(context)?.sourceHasAppTabBar;
  }

  @override
  bool updateShouldNotify(_AppBottomDockHandoffMetrics oldWidget) {
    return bottomInset != oldWidget.bottomInset ||
        frozen != oldWidget.frozen ||
        sourceHasAppTabBar != oldWidget.sourceHasAppTabBar;
  }
}

/// Pushes a Work Details Screen while preserving the source Bottom Dock until
/// the route has completely left the Navigator again.
Future<void> pushWorkDetailRoute(
  BuildContext context, {
  required WidgetBuilder builder,
}) async {
  final sourceScope = AppBottomDockTransitionScope._maybeStateOf(context);
  final view = View.of(context);
  final capturedBottomInset = view.viewPadding.bottom / view.devicePixelRatio;
  final lease = sourceScope?.arm(capturedBottomInset);
  if (lease != null) {
    await WidgetsBinding.instance.endOfFrame;
  }
  if (!context.mounted) {
    lease?.release();
    return;
  }

  final route = MaterialPageRoute<void>(
    builder: (_) => AppBottomDockTransitionScope._withHandoffMetrics(
      bottomInset: capturedBottomInset,
      frozen: true,
      sourceHasAppTabBar: sourceScope?.sourceHasAppTabBar ?? false,
      child: Builder(builder: builder),
    ),
  );
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
      part: _AppBottomDockHeroPart.miniPlayer,
      role: _role,
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
        part: _AppBottomDockHeroPart.tabBar,
        role: AppBottomDockRole.source,
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
            part: _AppBottomDockHeroPart.tabBar,
            role: AppBottomDockRole.workDetailsTarget,
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
    required this.part,
    required this.role,
    required this.enabled,
    required this.child,
    this.flightChild,
    this.suppressDescendantHeroes = false,
  });

  final Object tag;
  final _AppBottomDockHeroPart part;
  final AppBottomDockRole role;
  final bool enabled;
  final Widget child;
  final Widget? flightChild;
  final bool suppressDescendantHeroes;

  @override
  Widget build(BuildContext context) {
    if (!enabled || MediaQuery.disableAnimationsOf(context)) return child;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final dockExtent =
        AppBottomDockTransitionScope.bottomInsetOf(context) +
        appBottomDockNavigationBarHeight;
    final sourceHasAppTabBar =
        AppBottomDockTransitionScope.sourceHasAppTabBarOf(context);
    return Hero(
      tag: tag,
      transitionOnUserGestures: true,
      curve: Curves.linear,
      reverseCurve: Curves.linear,
      createRectTween: (begin, end) => _createBottomDockRectTween(
        begin,
        end,
        part: part,
        destinationRole: role,
        sourceHasAppTabBar: sourceHasAppTabBar,
        screenHeight: screenHeight,
        dockExtent: dockExtent,
      ),
      flightShuttleBuilder: _buildAppBottomDockFlight,
      child: _AppBottomDockHeroPayload(
        flightChild: flightChild,
        suppressDescendantHeroes: suppressDescendantHeroes,
        handoffBottomInset: AppBottomDockTransitionScope.handoffBottomInsetOf(
          context,
        ),
        child: suppressDescendantHeroes
            ? _DockArtworkHeroMode(enabled: false, child: child)
            : child,
      ),
    );
  }
}

RectTween _createBottomDockRectTween(
  Rect? begin,
  Rect? end, {
  required _AppBottomDockHeroPart part,
  required AppBottomDockRole destinationRole,
  required bool sourceHasAppTabBar,
  required double screenHeight,
  required double dockExtent,
}) {
  final push = destinationRole == AppBottomDockRole.workDetailsTarget;
  return RectTween(
    begin: _bottomDockEndpointRect(
      begin,
      part: part,
      role: push
          ? AppBottomDockRole.source
          : AppBottomDockRole.workDetailsTarget,
      sourceHasAppTabBar: sourceHasAppTabBar,
      screenHeight: screenHeight,
      dockExtent: dockExtent,
    ),
    end: _bottomDockEndpointRect(
      end,
      part: part,
      role: destinationRole,
      sourceHasAppTabBar: sourceHasAppTabBar,
      screenHeight: screenHeight,
      dockExtent: dockExtent,
    ),
  );
}

Rect? _bottomDockEndpointRect(
  Rect? rect, {
  required _AppBottomDockHeroPart part,
  required AppBottomDockRole role,
  required bool sourceHasAppTabBar,
  required double screenHeight,
  required double dockExtent,
}) {
  if (rect == null) return null;
  final isSource = role == AppBottomDockRole.source;
  switch (part) {
    case _AppBottomDockHeroPart.miniPlayer:
      final bottom = isSource && sourceHasAppTabBar
          ? screenHeight - dockExtent
          : screenHeight;
      return Rect.fromLTWH(
        rect.left,
        bottom - rect.height,
        rect.width,
        rect.height,
      );
    case _AppBottomDockHeroPart.tabBar:
      final top = isSource ? screenHeight - dockExtent : screenHeight;
      return Rect.fromLTWH(rect.left, top, rect.width, dockExtent);
  }
}

class _AppBottomDockHeroPayload extends StatelessWidget {
  const _AppBottomDockHeroPayload({
    required this.child,
    required this.flightChild,
    required this.suppressDescendantHeroes,
    required this.handoffBottomInset,
  });

  final Widget child;
  final Widget? flightChild;
  final bool suppressDescendantHeroes;
  final double? handoffBottomInset;

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
  final handoffBottomInset =
      preferred.handoffBottomInset ?? fallback.handoffBottomInset;
  final frozenFlightChild = handoffBottomInset == null
      ? flightChild
      : AppBottomDockTransitionScope.withHandoffBottomInset(
          flightContext,
          bottomInset: handoffBottomInset,
          child: flightChild,
        );
  final flightRootKey = fromHero.tag == _miniPlayerHeroTag
      ? appBottomDockMiniPlayerFlightRootKey
      : appBottomDockTabBarFlightRootKey;
  return IgnorePointer(
    child: Material(
      type: MaterialType.transparency,
      child: KeyedSubtree(
        key: flightRootKey,
        child: HeroMode(enabled: false, child: frozenFlightChild),
      ),
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
