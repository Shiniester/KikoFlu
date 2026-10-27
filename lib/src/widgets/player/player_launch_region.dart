import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'player_route.dart';
import 'player_vertical_gestures.dart';

/// The actions exposed by the Mini Player's full-player launch boundary.
abstract interface class PlayerLaunchRegionController {
  Future<void> openPlayer();

  Future<void> openQueue();

  bool allowPendingMiniPlayerDismiss();
}

typedef PlayerLaunchRegionBuilder =
    Widget Function(
      BuildContext context,
      PlayerLaunchRegionController controller,
      Widget artwork,
    );

/// Owns the short-lived launch session between the Mini Player and the
/// full-screen player route.
///
/// The nested Navigator keeps the root route's pointer alive while an upward
/// drag is being previewed. Once the route settles, the keyed player subtree is
/// handed to the root Navigator in the same frame.
class PlayerLaunchRegion extends StatefulWidget {
  const PlayerLaunchRegion({
    super.key,
    required this.sessionIdentity,
    required this.createConfiguration,
    required this.artworkBuilder,
    required this.builder,
  });

  final Object sessionIdentity;
  final AudioPlayerOpenConfiguration Function() createConfiguration;
  final WidgetBuilder artworkBuilder;
  final PlayerLaunchRegionBuilder builder;

  @override
  State<PlayerLaunchRegion> createState() => _PlayerLaunchRegionState();
}

class _PlayerLaunchRegionState extends State<PlayerLaunchRegion>
    with WidgetsBindingObserver
    implements PlayerLaunchRegionController {
  int? _pointer;
  Offset? _startPosition;
  VelocityTracker? _velocityTracker;
  bool _directionLocked = false;
  bool _directionRejected = false;
  bool _launchInProgress = false;
  bool _rejectPendingMiniDismiss = false;
  double _latestOpenDistance = 0;
  double _latestExtent = 1;
  _InteractivePlayerOpenSession? _interactiveSession;
  int _sessionGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant PlayerLaunchRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionIdentity != widget.sessionIdentity) {
      _abortInteractiveSession();
      _clearPointer();
    }
  }

  @override
  Future<void> openPlayer() => _openSurface(PlayerInitialSurface.main);

  @override
  Future<void> openQueue() => _openSurface(PlayerInitialSurface.queue);

  Future<void> _openSurface(PlayerInitialSurface initialSurface) async {
    if (!mounted || _launchInProgress) return;
    _launchInProgress = true;
    try {
      final route = widget.createConfiguration().createRoute(
        initialSurface: initialSurface,
      );
      if (!mounted) return;
      await Navigator.of(context).push<void>(route);
      await route.completed;
    } finally {
      _launchInProgress = false;
    }
  }

  @override
  bool allowPendingMiniPlayerDismiss() {
    if (!_rejectPendingMiniDismiss) return true;
    _rejectPendingMiniDismiss = false;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      key: const ValueKey('mini-player-upward-launcher'),
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: widget.builder(context, this, widget.artworkBuilder(context)),
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_pointer != null || _launchInProgress) return;
    _pointer = event.pointer;
    _startPosition = event.position;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    _directionLocked = false;
    _directionRejected = false;
    _rejectPendingMiniDismiss = false;
    _latestOpenDistance = 0;
    _latestExtent = MediaQuery.sizeOf(context).height.clamp(1, double.infinity);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _directionRejected) return;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    final start = _startPosition;
    if (start == null) return;
    final offset = event.position - start;
    if (!_directionLocked) {
      if (offset.distance < 8) return;
      if (offset.dy >= 0 || offset.dy.abs() < offset.dx.abs() * 1.2) {
        _directionRejected = true;
        return;
      }
      _directionLocked = true;
      _rejectPendingMiniDismiss = true;
      if (!MediaQuery.disableAnimationsOf(context)) {
        _startInteractiveSession();
      }
    }
    _latestOpenDistance = (-offset.dy).clamp(0.0, _latestExtent);
    _interactiveSession?.update(
      distance: _latestOpenDistance,
      extent: _latestExtent,
    );
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    final start = _startPosition;
    final distance = start == null ? 0.0 : start.dy - event.position.dy;
    final velocity = _velocityTracker?.getVelocity().pixelsPerSecond.dy ?? 0;
    if (_directionLocked) {
      final extent = _latestExtent;
      final session = _interactiveSession;
      if (session != null) {
        unawaited(
          _finishInteractiveSession(
            session,
            velocity: velocity,
            extent: extent,
          ),
        );
      } else if (shouldCompletePlayerOpenGesture(
        visualProgress: distance / extent.clamp(1, double.infinity),
        velocity: velocity,
      )) {
        unawaited(openPlayer());
      }
      _clearPointer();
      return;
    }
    _clearPointer();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    final session = _interactiveSession;
    if (session != null) {
      unawaited(_cancelInteractiveSession(session));
    }
    _clearPointer();
  }

  void _startInteractiveSession() {
    if (!mounted || _interactiveSession != null || _launchInProgress) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final rootNavigator = Navigator.of(context);
    final configuration = widget.createConfiguration();
    final generation = ++_sessionGeneration;
    _launchInProgress = true;
    final session = _InteractivePlayerOpenSession(
      overlay: overlay,
      rootNavigator: rootNavigator,
      configuration: configuration,
      onRootRouteClosed: () {
        if (!mounted || generation != _sessionGeneration) return;
        _launchInProgress = false;
      },
    );
    _interactiveSession = session;
    session.update(distance: _latestOpenDistance, extent: _latestExtent);
    unawaited(session.start());
  }

  Future<void> _finishInteractiveSession(
    _InteractivePlayerOpenSession session, {
    required double velocity,
    required double extent,
  }) async {
    if (!mounted || !identical(_interactiveSession, session)) return;
    final completed = await session.finish(velocity: velocity, extent: extent);
    if (!mounted || !identical(_interactiveSession, session)) return;
    _interactiveSession = null;
    if (!completed) {
      _launchInProgress = false;
    }
  }

  Future<void> _cancelInteractiveSession(
    _InteractivePlayerOpenSession session,
  ) async {
    await session.cancel();
    if (!mounted || !identical(_interactiveSession, session)) return;
    _interactiveSession = null;
    _launchInProgress = false;
  }

  void _abortInteractiveSession() {
    if (_interactiveSession == null) return;
    ++_sessionGeneration;
    _interactiveSession?.abort();
    _interactiveSession = null;
    _launchInProgress = false;
  }

  void _clearPointer() {
    _pointer = null;
    _startPosition = null;
    _velocityTracker = null;
    _directionLocked = false;
    _directionRejected = false;
    _latestOpenDistance = 0;
    _latestExtent = 1;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    _abortInteractiveSession();
    _clearPointer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _abortInteractiveSession();
    _clearPointer();
    super.dispose();
  }
}

/// A short-lived route host used only while an upward Mini Player pointer is
/// still active.
class _InteractivePlayerOpenSession {
  _InteractivePlayerOpenSession({
    required this.overlay,
    required this.rootNavigator,
    required this.configuration,
    required this.onRootRouteClosed,
  });

  final OverlayState overlay;
  final NavigatorState rootNavigator;
  final AudioPlayerOpenConfiguration configuration;
  final VoidCallback onRootRouteClosed;

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey _playerPageKey = GlobalKey();
  final Completer<void> _routeReady = Completer<void>();
  OverlayEntry? _entry;
  AudioPlayerPageRoute<void>? _route;
  double _distance = 0;
  double _extent = 1;
  bool _started = false;
  bool _disposed = false;
  bool _settling = false;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _entry = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: IgnorePointer(
          child: Navigator(
            key: _navigatorKey,
            requestFocus: false,
            onGenerateInitialRoutes: (navigator, initialRoute) => [
              PageRouteBuilder<void>(
                settings: const RouteSettings(
                  name: '_interactive_player_source',
                ),
                opaque: false,
                barrierColor: Colors.transparent,
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
                pageBuilder: (context, animation, secondaryAnimation) =>
                    const SizedBox.expand(),
              ),
            ],
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
    await WidgetsBinding.instance.endOfFrame;
    if (_disposed) return;
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      abort();
      return;
    }
    final route = configuration.createRoute(playerKey: _playerPageKey);
    _route = route;
    unawaited(navigator.push<void>(route));
    await WidgetsBinding.instance.endOfFrame;
    if (_disposed) return;
    if (!route.beginVerticalOpenGesture()) {
      abort();
      return;
    }
    route.updateVerticalOpenGesture(distance: _distance, extent: _extent);
    if (!_routeReady.isCompleted) _routeReady.complete();
  }

  void update({required double distance, required double extent}) {
    if (_disposed || _settling) return;
    _distance = distance.clamp(0.0, extent);
    _extent = extent.clamp(1, double.infinity);
    _route?.updateVerticalOpenGesture(distance: _distance, extent: _extent);
  }

  Future<bool> finish({required double velocity, required double extent}) {
    return _settle(complete: true, velocity: velocity, extent: extent);
  }

  Future<bool> cancel() {
    return _settle(complete: false, velocity: 0, extent: _extent);
  }

  Future<bool> _settle({
    required bool complete,
    required double velocity,
    required double extent,
  }) async {
    if (_disposed || _settling) return false;
    _settling = true;
    if (!_routeReady.isCompleted) {
      try {
        await _routeReady.future;
      } catch (_) {
        abort();
        return false;
      }
    }
    if (_disposed) return false;
    final route = _route;
    if (route == null) {
      abort();
      return false;
    }
    final opened = complete
        ? await route.endVerticalOpenGesture(velocity: velocity, extent: extent)
        : await route.cancelVerticalOpenGesture();
    if (_disposed) return false;
    if (!opened) {
      _removeOverlay();
      return false;
    }

    final rootRoute = configuration.createRoute(
      playerKey: _playerPageKey,
      handoff: true,
    );
    _removeOverlay();
    unawaited(rootNavigator.push<void>(rootRoute));
    unawaited(rootRoute.completed.whenComplete(onRootRouteClosed));
    return true;
  }

  void abort() {
    if (_disposed) return;
    if (!_routeReady.isCompleted) _routeReady.complete();
    _removeOverlay();
  }

  void _removeOverlay() {
    if (_disposed) return;
    _disposed = true;
    _entry?.remove();
    _entry = null;
  }
}
