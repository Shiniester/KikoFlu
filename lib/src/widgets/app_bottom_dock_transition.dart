import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';

const double appBottomDockNavigationBarHeight = 58;
@visibleForTesting
const appBottomDockMiniPlayerHandoffRootKey = ValueKey<String>(
  'app-bottom-dock-mini-player-handoff-root',
);
@visibleForTesting
const appBottomDockTabBarHandoffRootKey = ValueKey<String>(
  'app-bottom-dock-tab-bar-handoff-root',
);

enum AppBottomDockRole { source, workDetailsTarget }

enum _DockPart { miniPlayer, tabBar }

/// Owns outgoing Dock handoffs without owning playback or app navigation.
class AppBottomDockTransitionScope extends StatefulWidget {
  const AppBottomDockTransitionScope({super.key, required this.child});
  final Widget child;
  @override
  State<AppBottomDockTransitionScope> createState() => _DockScopeState();
  static _DockScopeState? _maybeStateOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_DockHost>()?.state;
  static double? handoffBottomInsetOf(BuildContext context) {
    final metrics = _DockMetrics.maybeOf(context);
    return metrics?.frozen == true ? metrics!.bottomInset : null;
  }

  static double bottomInsetOf(BuildContext context) =>
      _DockMetrics.maybeOf(context)?.bottomInset ??
      MediaQuery.viewPaddingOf(context).bottom;
  static bool artworkHeroEnabledOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_DockArtworkHeroMode>()
          ?.enabled ??
      true;
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
}

class _DockScopeState extends State<AppBottomDockTransitionScope> {
  final List<_DockSession> _handoffs = [];
  final Map<_DockPart, _DockEndpointState> _endpoints = {};
  _DockSession? get activeSession => _handoffs.lastOrNull;
  PageRoute<void>? get returningRoute {
    for (final session in _handoffs.reversed) {
      final route = session.route;
      if (route.navigator != null && !route.isActive) return route;
    }
    return null;
  }

  void arm(_DockSession session) => setState(() => _handoffs.add(session));
  void release(_DockSession session) {
    session.dispose();
    if (mounted) setState(() => _handoffs.remove(session));
  }

  @override
  Widget build(BuildContext context) {
    final inherited = _DockMetrics.maybeOf(context);
    final session = activeSession;
    return _DockMetrics(
      bottomInset:
          session?.bottomInset ??
          inherited?.bottomInset ??
          MediaQuery.viewPaddingOf(context).bottom,
      frozen: session != null || (inherited?.frozen ?? false),
      // Incoming and outgoing handoffs are independent for nested routes.
      incoming: inherited?.incoming,
      child: _DockHost(state: this, outgoing: session, child: widget.child),
    );
  }

  @override
  void dispose() {
    for (final session in _handoffs) {
      session.dispose();
    }
    super.dispose();
  }
}

class _DockHost extends InheritedWidget {
  const _DockHost({
    required this.state,
    required this.outgoing,
    required super.child,
  });
  final _DockScopeState state;
  final _DockSession? outgoing;
  @override
  bool updateShouldNotify(_DockHost oldWidget) =>
      outgoing != oldWidget.outgoing;
}

class _DockMetrics extends InheritedWidget {
  const _DockMetrics({
    required this.bottomInset,
    required this.frozen,
    required this.incoming,
    required super.child,
  });
  final double bottomInset;
  final bool frozen;
  final _DockSession? incoming;
  static _DockMetrics? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DockMetrics>();
  @override
  bool updateShouldNotify(_DockMetrics oldWidget) =>
      bottomInset != oldWidget.bottomInset ||
      frozen != oldWidget.frozen ||
      incoming != oldWidget.incoming;
}

/// Invalidates the page image when its Dock becomes an equal-size placeholder.
class AppBottomDockSnapshotNotification extends Notification {
  const AppBottomDockSnapshotNotification();
}

Future<void> pushWorkDetailRoute(
  BuildContext context, {
  required WidgetBuilder builder,
}) => pushBottomDockRoute(context, builder: builder);

/// Retains the source scope until the destination has completely returned.
Future<void> pushBottomDockRoute(
  BuildContext context, {
  required WidgetBuilder builder,
}) async {
  final sourceScope = AppBottomDockTransitionScope._maybeStateOf(context);
  final sourceRoute = ModalRoute.of(context);
  final returningRoute = sourceScope?.returningRoute;
  if (returningRoute != null) {
    await returningRoute.completed;
    if (!context.mounted) return;
  }
  final view = View.of(context);
  final bottomInset = view.viewPadding.bottom / view.devicePixelRatio;
  final session = sourceScope != null
      ? _DockSession(
          enabled:
              MediaQuery.orientationOf(context) == Orientation.portrait &&
              !MediaQuery.disableAnimationsOf(context),
          bottomInset: bottomInset,
          source: sourceScope,
          view: view,
        )
      : null;
  final route = _DockPageRoute(
    session: session,
    builder: (_) => _DockMetrics(
      bottomInset: bottomInset,
      frozen: true,
      incoming: session,
      child: Builder(builder: builder),
    ),
  );
  session?.route = route;
  if (session != null) sourceScope!.arm(session);
  try {
    if (session != null) await WidgetsBinding.instance.endOfFrame;
    if (!context.mounted || sourceRoute?.isCurrent == false) return;
    await Navigator.of(context).push<void>(route);
    await route.completed;
  } finally {
    if (session != null) sourceScope!.release(session);
  }
}

class _DockSession extends ChangeNotifier with WidgetsBindingObserver {
  _DockSession({
    required this.enabled,
    required this.bottomInset,
    required this.source,
    required this.view,
  });
  final bool enabled;
  final double bottomInset;
  final _DockScopeState source;
  final FlutterView view;
  _DockEndpointState? get sourceMini => source._endpoints[_DockPart.miniPlayer];
  _DockEndpointState? get sourceTab => source._endpoints[_DockPart.tabBar];
  late final _DockPageRoute route;
  _DockEndpointState? targetMini;
  Animation<double>? _animation;
  ValueNotifier<bool>? _gesture;
  bool _ready = false;
  bool _disposed = false;
  bool inTransit = false;
  bool sourceCovered = false;
  double get distance =>
      sourceTab == null ? 0 : appBottomDockNavigationBarHeight + bottomInset;
  void attach(Animation<double> animation, ValueNotifier<bool> gesture) {
    if (identical(_animation, animation)) return;
    _animation = animation;
    _gesture = gesture;
    animation.addListener(_sync);
    animation.addStatusListener(_onStatus);
    gesture.addListener(_sync);
    WidgetsBinding.instance.addObserver(this);
  }

  void prepareAfterLayout() {
    if (_disposed || _ready) return;
    sourceMini?.measure();
    sourceTab?.measure();
    targetMini?.measure();
    if ((sourceMini?.extent.height ?? 0) > 0 &&
        (targetMini?.extent.height ?? 0) == 0) {
      return;
    }
    _ready = true;
    _sync();
  }

  void _onStatus(AnimationStatus _) => _sync();
  @override
  void didChangeMetrics() => _sync();

  void _sync() {
    if (_disposed || !_ready || _animation == null) return;
    final status = _animation!.status;
    final gesture = route.isCurrent && (_gesture?.value ?? false);
    final portrait = view.physicalSize.height >= view.physicalSize.width;
    final moving =
        portrait &&
        (gesture ||
            status == AnimationStatus.forward ||
            status == AnimationStatus.reverse);
    final covered = portrait && status != AnimationStatus.dismissed;
    if (moving == inTransit && covered == sourceCovered) return;
    inTransit = moving;
    sourceCovered = covered;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _animation?.removeListener(_sync);
    _animation?.removeStatusListener(_onStatus);
    _gesture?.removeListener(_sync);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class _DockPageRoute extends MaterialPageRoute<void> {
  _DockPageRoute({required super.builder, required this.session});
  final _DockSession? session;
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final page = super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      child,
    );
    final handoff = session;
    if (handoff == null || !handoff.enabled) return page;
    handoff.attach(animation, navigator!.userGestureInProgressNotifier);
    return Stack(
      fit: StackFit.expand,
      children: [
        page,
        _DockTransitionLayer(session: handoff, animation: animation),
      ],
    );
  }
}

class _DockTransitionLayer extends StatefulWidget {
  const _DockTransitionLayer({required this.session, required this.animation});
  final _DockSession session;
  final Animation<double> animation;
  @override
  State<_DockTransitionLayer> createState() => _DockTransitionLayerState();
}

class _DockTransitionLayerState extends State<_DockTransitionLayer> {
  late final CurvedAnimation _curve;
  @override
  void initState() {
    super.initState();
    _curve = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeInOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.session.prepareAfterLayout();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.session, widget.session._gesture]),
    builder: (context, _) {
      final session = widget.session;
      if (!session.inTransit) return const SizedBox.shrink();
      final mini = session.targetMini;
      final tab = session.sourceTab;
      if (mini == null && tab == null) return const SizedBox.shrink();
      return LayoutBuilder(
        builder: (context, constraints) {
          final position = Tween<Offset>(
            begin: Offset.zero,
            end: Offset(0, session.distance / constraints.maxHeight),
          ).animate(session._gesture!.value ? widget.animation : _curve);
          final dock = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (mini != null)
                KeyedSubtree(
                  key: appBottomDockMiniPlayerHandoffRootKey,
                  child: mini.payload(inOverlay: true),
                ),
              if (tab != null)
                KeyedSubtree(
                  key: appBottomDockTabBarHandoffRootKey,
                  child: tab.payload(inOverlay: true),
                ),
            ],
          );
          return ClipRect(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: SlideTransition(
                  position: position,
                  child: SizedBox.expand(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Material(
                        type: MaterialType.transparency,
                        child: _DockArtworkHeroMode(
                          enabled: false,
                          child: HeroMode(
                            enabled: false,
                            child:
                                AppBottomDockTransitionScope.withHandoffBottomInset(
                                  context,
                                  bottomInset: session.bottomInset,
                                  child: _DockMetrics(
                                    bottomInset: session.bottomInset,
                                    frozen: true,
                                    incoming: session,
                                    child: dock,
                                  ),
                                ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
  @override
  void dispose() {
    _curve.dispose();
    super.dispose();
  }
}

class AppBottomDockMiniPlayer extends StatelessWidget {
  const AppBottomDockMiniPlayer.source({super.key, required this.child});
  const AppBottomDockMiniPlayer.target({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      _DockEndpoint(part: _DockPart.miniPlayer, child: child);
}

class AppBottomDockTabBar extends StatelessWidget {
  const AppBottomDockTabBar.source({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      _DockEndpoint(part: _DockPart.tabBar, child: child);
}

class _DockEndpoint extends StatefulWidget {
  const _DockEndpoint({required this.part, required this.child});
  final _DockPart part;
  final Widget child;
  @override
  State<_DockEndpoint> createState() => _DockEndpointState();
}

class _DockEndpointState extends State<_DockEndpoint> {
  final GlobalKey _payloadKey = GlobalKey();
  _DockScopeState? _owner;
  _DockSession? _incoming;
  _DockSession? _outgoing;
  CapturedThemes? _themes;
  Size extent = Size.zero;
  void measure() {
    final box = _payloadKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) extent = box.size;
  }

  Widget payload({bool inOverlay = false}) {
    Widget result = KeyedSubtree(key: _payloadKey, child: widget.child);
    if (inOverlay) result = _themes!.wrap(result);
    return result;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final host = context.dependOnInheritedWidgetOfExactType<_DockHost>();
    final owner = host?.state;
    if (_owner != owner) {
      _owner?._endpoints.remove(widget.part);
      _owner = owner;
    }
    owner?._endpoints[widget.part] = this;
    final incoming = _DockMetrics.maybeOf(context)?.incoming;
    final target = incoming?.route == ModalRoute.of(context) ? incoming : null;
    final outgoing = host?.outgoing;
    if (_incoming != target || _outgoing != outgoing) {
      _incoming?.removeListener(_onSessionChanged);
      _outgoing?.removeListener(_onSessionChanged);
      _incoming = target;
      _outgoing = outgoing;
      _incoming?.addListener(_onSessionChanged);
      _outgoing?.addListener(_onSessionChanged);
    }
    if (widget.part == _DockPart.miniPlayer && target != null) {
      target.targetMini = this;
    }
    _themes = InheritedTheme.capture(
      from: context,
      to: Navigator.of(context).context,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      measure();
      target?.prepareAfterLayout();
    });
  }

  void _onSessionChanged() {
    if (!mounted) return;
    measure();
    setState(() {});
    const AppBottomDockSnapshotNotification().dispatch(context);
  }

  @override
  Widget build(BuildContext context) {
    final movesIntoLayer =
        ((_incoming?.inTransit ?? false) &&
            widget.part == _DockPart.miniPlayer) ||
        ((_outgoing?.inTransit ?? false) && widget.part == _DockPart.tabBar);
    if (movesIntoLayer) {
      return SizedBox(width: double.infinity, height: extent.height);
    }
    final covered = _outgoing?.sourceCovered ?? false;
    return _DockArtworkHeroMode(
      enabled: !covered,
      child: HeroMode(
        enabled: !covered,
        child: covered
            ? SizedBox(
                width: double.infinity,
                height: extent.height,
                child: Offstage(child: payload()),
              )
            : payload(),
      ),
    );
  }

  @override
  void dispose() {
    if (_incoming?.targetMini == this) _incoming?.targetMini = null;
    _incoming?.removeListener(_onSessionChanged);
    _outgoing?.removeListener(_onSessionChanged);
    if (_owner?._endpoints[widget.part] == this) {
      _owner?._endpoints.remove(widget.part);
    }
    super.dispose();
  }
}

class _DockArtworkHeroMode extends InheritedWidget {
  const _DockArtworkHeroMode({required this.enabled, required super.child});
  final bool enabled;
  @override
  bool updateShouldNotify(_DockArtworkHeroMode oldWidget) =>
      enabled != oldWidget.enabled;
}
