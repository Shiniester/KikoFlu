import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show kDoubleTapTimeout, kLongPressTimeout, kTouchSlop;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart'
    show
        AxisDirection,
        RenderBox,
        RenderParagraph,
        RenderViewport,
        ScrollCacheExtent,
        ScrollDirection,
        ViewportOffset;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart'
    show PositionDiscontinuity, PositionDiscontinuityReason;

import '../../models/lyric.dart';
import '../../providers/audio_provider.dart';
import '../../providers/lyric_provider.dart';
import '../../providers/player_lyric_style_provider.dart';
import '../../utils/string_utils.dart';
import 'player_slice_controls.dart';
import 'player_seek_preview.dart';
import '../../../l10n/app_localizations.dart';

const _lyricTapFeedbackDuration = Duration(milliseconds: 500);
const _lyricTapFeedbackStaticDuration = Duration(milliseconds: 300);
const _lyricTapFeedbackFallbackWindow = Duration(milliseconds: 360);
const _lyricTapFeedbackAlpha = 0.10;
const _lyricTapFeedbackRadius = 14.0;
const _lyricAdaptiveBaseWidth = 334.0;
const _lyricAdaptiveMaxScale = 1.45;
const _lyricPreviewFadeExtent = 12.0;
const _lyricSpringScaleRest = 0.97;
const _lyricSpringCascadeStep = Duration(milliseconds: 50);

SpringDescription _lyricPositionSpring(PlayerLyricSpringPreset preset) {
  final criticalDamping = 2 * math.sqrt(preset.mass * preset.stiffness);
  if (preset.damping < criticalDamping) {
    return SpringDescription(
      mass: preset.mass,
      damping: preset.damping,
      stiffness: preset.stiffness,
    );
  }
  return SpringDescription.withDampingRatio(
    mass: preset.mass,
    stiffness: preset.stiffness,
  );
}

class _LyricSpringMotion {
  _LyricSpringMotion({
    required double startY,
    required this.targetY,
    required this.velocityY,
    required this.startAt,
    required this.delay,
    required SpringDescription positionSpring,
  }) : startY = startY,
       positionSimulation = SpringSimulation(
         positionSpring,
         startY,
         targetY,
         velocityY,
       );

  final double startY;
  final double targetY;
  final double velocityY;
  final double startAt;
  final double delay;
  final SpringSimulation positionSimulation;

  _LyricSpringSample sample(double now) {
    final elapsed = now - startAt - delay;
    if (elapsed <= 0) {
      return (y: startY, velocityY: 0, moving: false, done: false);
    }
    final positionDone = positionSimulation.isDone(elapsed);
    return (
      y: positionSimulation.x(elapsed),
      velocityY: positionDone ? 0 : positionSimulation.dx(elapsed),
      moving: !positionDone,
      done: positionDone,
    );
  }
}

typedef _LyricEmphasisValue = ({double opacity, double scale});

typedef _LyricEmphasisSample = ({double opacity, double scale, bool done});

class _LyricEmphasisMotion {
  _LyricEmphasisMotion({
    required this.startOpacity,
    required this.targetOpacity,
    required this.startScale,
    required this.targetScale,
    required this.startAt,
    required this.delay,
    required double velocity,
    required SpringDescription spring,
  }) : progressSimulation = SpringSimulation(spring, 0, 1, velocity);

  final double startOpacity;
  final double targetOpacity;
  final double startScale;
  final double targetScale;
  final double startAt;
  final double delay;
  final SpringSimulation progressSimulation;
  double _progress = 0;

  _LyricEmphasisSample sample(double now) {
    final elapsed = now - startAt - delay;
    if (elapsed > 0) {
      final done = progressSimulation.isDone(elapsed);
      final progress = done
          ? 1.0
          : progressSimulation.x(elapsed).clamp(0.0, 1.0).toDouble();
      _progress = math.max(_progress, progress);
    }
    return (
      opacity: startOpacity + (targetOpacity - startOpacity) * _progress,
      scale: startScale + (targetScale - startScale) * _progress,
      done: _progress >= 1,
    );
  }

  double progressVelocity(double now) {
    final elapsed = now - startAt - delay;
    return elapsed <= 0 || _progress >= 1 ? 0 : progressSimulation.dx(elapsed);
  }
}

class _LyricScrollMotion {
  _LyricScrollMotion({
    required this.start,
    required this.target,
    required this.velocity,
    required this.startAt,
    required SpringDescription spring,
  }) : simulation = SpringSimulation(spring, start, target, velocity);

  final double start;
  final double target;
  final double velocity;
  final double startAt;
  final SpringSimulation simulation;

  ({double position, double velocity, bool done}) sample(double now) {
    final elapsed = now - startAt;
    if (elapsed <= 0) return (position: start, velocity: velocity, done: false);
    final done = simulation.isDone(elapsed);
    return (
      position: simulation.x(elapsed),
      velocity: done ? 0 : simulation.dx(elapsed),
      done: done,
    );
  }
}

class _RetainedLyricListView extends ListView {
  _RetainedLyricListView.builder({
    super.key,
    super.controller,
    super.physics,
    super.padding,
    required super.itemBuilder,
    super.itemCount,
    super.itemExtentBuilder,
    required this.motionFrame,
    required this.overlayRowsBuilder,
  }) : super.builder(addRepaintBoundaries: false, addSemanticIndexes: false);

  final ValueListenable<int> motionFrame;
  final List<Widget> Function() overlayRowsBuilder;

  @override
  Widget buildViewport(
    BuildContext context,
    ViewportOffset offset,
    AxisDirection axisDirection,
    List<Widget> slivers,
  ) {
    return Stack(
      fit: StackFit.expand,
      children: [
        super.buildViewport(context, offset, axisDirection, slivers),
        AnimatedBuilder(
          animation: Listenable.merge([motionFrame, offset]),
          builder: (context, child) => Semantics(
            tagForChildren: RenderViewport.useTwoPaneSemantics,
            child: Stack(fit: StackFit.expand, children: overlayRowsBuilder()),
          ),
        ),
      ],
    );
  }
}

typedef _LyricSpringSample = ({
  double y,
  double velocityY,
  bool moving,
  bool done,
});

double playerLyricPreviewHeight({
  required double width,
  required double fontSize,
  required double lineHeight,
  required TextScaler textScaler,
  required int lineCount,
  required bool compact,
  double maxHeight = double.infinity,
}) {
  final widthScale = _lyricWidthScale(width);
  final activeFontSize = fontSize * widthScale + (compact ? 0 : 1);
  final itemExtent = _lyricPreviewItemExtent(
    activeFontSize,
    lineHeight,
    textScaler,
  );
  return math.min(
    maxHeight,
    _visiblePreviewLineCount(lineCount, maxHeight, itemExtent) * itemExtent +
        _lyricPreviewFadeExtent * 2,
  );
}

double _lyricWidthScale(double width) => (width / _lyricAdaptiveBaseWidth)
    .clamp(1.0, _lyricAdaptiveMaxScale)
    .toDouble();

double _lyricPreviewItemExtent(
  double fontSize,
  double lineHeight,
  TextScaler textScaler,
) => (textScaler.scale(fontSize) * lineHeight + 11)
    .ceilToDouble()
    .clamp(25.0, double.infinity)
    .toDouble();

double _lyricActiveTextScale(
  TextStyle activeStyle,
  TextStyle inactiveStyle,
  TextScaler textScaler,
) {
  final inactiveSize = textScaler.scale(inactiveStyle.fontSize ?? 14);
  if (inactiveSize <= 0) return 1;
  return textScaler.scale(activeStyle.fontSize ?? 14) / inactiveSize;
}

Animatable<double> _lyricTapFeedbackOpacity() {
  return TweenSequence<double>([
    TweenSequenceItem<double>(
      tween: Tween<double>(
        begin: 0,
        end: 1,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 80,
    ),
    TweenSequenceItem<double>(tween: ConstantTween<double>(1), weight: 120),
    TweenSequenceItem<double>(
      tween: Tween<double>(
        begin: 1,
        end: 0,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 300,
    ),
  ]);
}

/// Tracks pointer sequences without competing with a lyric row's [InkWell].
///
/// [InkWell] waits for the double-tap timeout before reporting a single tap.
/// This passive listener reports only visual feedback on a valid pointer up;
/// the [InkWell] still owns the single/double-tap action decision.
class _LyricPointerTracker {
  _LyricPointerTracker({required this.onTap, required this.onInvalid});

  final ValueChanged<int> onTap;
  final ValueChanged<int> onInvalid;
  final Map<int, _LyricPointerSequence> _pointers = {};

  void handlePointerDown(PointerDownEvent event, int index) {
    _pointers[event.pointer]?.cancel();
    final sequence = _LyricPointerSequence(
      index: index,
      downPosition: event.position,
    );
    _pointers[event.pointer] = sequence;
    sequence.longPressTimer = Timer(kLongPressTimeout, () {
      if (identical(_pointers[event.pointer], sequence)) {
        _invalidate(sequence);
      }
    });
  }

  void handlePointerMove(PointerMoveEvent event) {
    final sequence = _pointers[event.pointer];
    if (sequence == null ||
        (event.position - sequence.downPosition).distance <= kTouchSlop) {
      return;
    }
    _invalidate(sequence);
  }

  void handlePointerUp(PointerUpEvent event) {
    final sequence = _pointers.remove(event.pointer);
    if (sequence == null) return;
    sequence.cancel();
    if (sequence.valid) onTap(sequence.index);
  }

  void handlePointerCancel(PointerCancelEvent event) {
    final sequence = _pointers.remove(event.pointer);
    if (sequence == null) return;
    _invalidate(sequence);
  }

  void clear() {
    for (final sequence in _pointers.values) {
      sequence.cancel();
    }
    _pointers.clear();
  }

  void _invalidate(_LyricPointerSequence sequence) {
    if (!sequence.valid) return;
    sequence.valid = false;
    sequence.cancel();
    onInvalid(sequence.index);
  }
}

class _LyricPointerSequence {
  _LyricPointerSequence({required this.index, required this.downPosition});

  final int index;
  final Offset downPosition;
  bool valid = true;
  Timer? longPressTimer;

  void cancel() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }
}

Widget _buildLyricTapFeedbackSurface({
  required Animation<double> opacity,
  required bool active,
  required bool reducedMotion,
  required Color color,
  required String keyValue,
  required Widget child,
}) {
  final animation = active ? opacity : const AlwaysStoppedAnimation<double>(0);
  return AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      final progress = active ? (reducedMotion ? 1.0 : opacity.value) : 0.0;
      return DecoratedBox(
        key: ValueKey(keyValue),
        decoration: BoxDecoration(
          color: color.withValues(alpha: _lyricTapFeedbackAlpha * progress),
          borderRadius: BorderRadius.circular(_lyricTapFeedbackRadius),
        ),
        child: child,
      );
    },
  );
}

/// Shared top/bottom transparency used by both compact and full lyric
/// viewports. [visibleBottomInset] keeps the lower fade attached to the
/// actually visible edge when the keyboard clips the full lyric surface.
LinearGradient playerLyricEdgeFadeGradient(
  Rect bounds, {
  double visibleBottomInset = 0,
  double topFadeExtent = 48,
  double bottomFadeExtent = 72,
}) {
  if (bounds.height <= 0) {
    return const LinearGradient(colors: [Colors.transparent, Colors.white]);
  }
  final visibleEnd = ((bounds.height - visibleBottomInset) / bounds.height)
      .clamp(0.02, 1.0)
      .toDouble();
  final topOpaque = (topFadeExtent / bounds.height)
      .clamp(0.0, visibleEnd * 0.35)
      .toDouble();
  final fadeHeight = (bottomFadeExtent / bounds.height)
      .clamp(0.0, visibleEnd * 0.4)
      .toDouble();
  final bottomOpaque = (visibleEnd - fadeHeight)
      .clamp(topOpaque, visibleEnd)
      .toDouble();
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: const [
      Colors.transparent,
      Colors.white,
      Colors.white,
      Colors.transparent,
    ],
    stops: [0, topOpaque, bottomOpaque, visibleEnd],
  );
}

/// Small, single-line lyric display used by the wide cover pane.
class LyricDisplay extends ConsumerWidget {
  const LyricDisplay({super.key, this.albumName});

  final String? albumName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentLyric = ref.watch(currentLyricTextProvider);
    final hasLyrics = ref.watch(
      lyricControllerProvider.select((state) => state.lyrics.isNotEmpty),
    );
    final lyricSettings = ref.watch(playerLyricSettingsProvider);

    if (hasLyrics) {
      return AnimatedSwitcher(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 220),
        child: Container(
          key: ValueKey(currentLyric),
          constraints: const BoxConstraints(minHeight: 24),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          child: Text(
            currentLyric ?? '♪',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.w700,
              height: lyricSettings.smallLineHeight,
              fontSize: lyricSettings.smallFontSize,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (albumName?.trim().isNotEmpty == true) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          albumName!,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// A compact odd-numbered lyric preview centred on the active line. It only
/// listens to the effective lyric index, so normal position ticks do not
/// rebuild it.
class ThreeLineLyricDisplay extends ConsumerStatefulWidget {
  const ThreeLineLyricDisplay({
    super.key,
    required this.onSeekRequested,
    this.compact = false,
    this.lineCount = 3,
    this.enableLineTapFeedback = false,
    this.textHorizontalPadding = 0,
    this.onLineDoubleTap,
  }) : assert(lineCount == 3 || lineCount == 5);

  final ValueChanged<Duration> onSeekRequested;
  final bool compact;
  final int lineCount;
  final bool enableLineTapFeedback;
  final double textHorizontalPadding;
  final VoidCallback? onLineDoubleTap;

  @override
  ConsumerState<ThreeLineLyricDisplay> createState() =>
      _ThreeLineLyricDisplayState();
}

class _ThreeLineLyricDisplayState extends ConsumerState<ThreeLineLyricDisplay>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late final _LyricPointerTracker _pointerTracker;
  late final AnimationController _tapFeedbackController;
  late final Animation<double> _tapFeedbackOpacity;
  Timer? _resumeFollowTimer;
  Timer? _tapFeedbackClearTimer;
  Timer? _tapFeedbackDedupeTimer;
  final Map<int, Timer> _pointerFeedbackSuppressions = {};
  bool _isUserBrowsing = false;
  bool _userScrollInProgress = false;
  int _latestIndex = -1;
  int? _lastIndex;
  int? _lyricsSignature;
  int _scrollGeneration = 0;
  double? _lastItemExtent;
  int? _tapFeedbackIndex;
  int? _tapFeedbackDedupeIndex;
  bool _tickersEnabled = true;

  @override
  void initState() {
    super.initState();
    _pointerTracker = _LyricPointerTracker(
      onTap: _handlePointerTap,
      onInvalid: _handlePointerInvalid,
    );
    _tapFeedbackController = AnimationController(
      vsync: this,
      duration: _lyricTapFeedbackDuration,
    )..addStatusListener(_handleTapFeedbackStatus);
    _tapFeedbackOpacity = _lyricTapFeedbackOpacity().animate(
      _tapFeedbackController,
    );
  }

  @override
  void didUpdateWidget(covariant ThreeLineLyricDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enableLineTapFeedback && !widget.enableLineTapFeedback) {
      _clearTapFeedbackState(notify: false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    if (_tickersEnabled && !enabled) {
      final generation = ++_scrollGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            generation != _scrollGeneration ||
            !_scrollController.hasClients) {
          return;
        }
        // Cancel the running scroll instead of replaying it when visible again.
        _scrollController.jumpTo(_scrollController.offset);
      });
    }
    final becameVisible = !_tickersEnabled && enabled;
    _tickersEnabled = enabled;
    if (becameVisible &&
        !_isUserBrowsing &&
        _latestIndex >= 0 &&
        _lastItemExtent != null) {
      _positionCurrentLine(
        _latestIndex,
        _lastItemExtent!,
        animate: false,
        deferUntilLayout: false,
      );
    }
  }

  @override
  void dispose() {
    _resumeFollowTimer?.cancel();
    _clearTapFeedbackState(notify: false);
    _scrollGeneration++;
    _tapFeedbackController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleTapFeedbackStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _tapFeedbackIndex == null) {
      return;
    }
    if (mounted) setState(() => _tapFeedbackIndex = null);
  }

  void _clearTapFeedback({bool notify = true}) {
    _tapFeedbackClearTimer?.cancel();
    _tapFeedbackClearTimer = null;
    _tapFeedbackController.stop(canceled: true);
    if (notify && mounted) {
      if (_tapFeedbackIndex != null) {
        setState(() => _tapFeedbackIndex = null);
      }
    } else {
      _tapFeedbackIndex = null;
    }
  }

  void _clearTapFeedbackState({bool notify = true}) {
    _clearTapFeedback(notify: notify);
    _tapFeedbackDedupeTimer?.cancel();
    _tapFeedbackDedupeTimer = null;
    _tapFeedbackDedupeIndex = null;
    for (final timer in _pointerFeedbackSuppressions.values) {
      timer.cancel();
    }
    _pointerFeedbackSuppressions.clear();
    _pointerTracker.clear();
  }

  void _handlePointerTap(int index) {
    if (!widget.enableLineTapFeedback || !mounted) {
      return;
    }
    final duplicate =
        _tapFeedbackDedupeIndex == index && _tapFeedbackDedupeTimer != null;
    if (!duplicate) _showTapFeedback(index);
    _tapFeedbackDedupeIndex = index;
    _tapFeedbackDedupeTimer?.cancel();
    _tapFeedbackDedupeTimer = Timer(kDoubleTapTimeout, () {
      _tapFeedbackDedupeTimer = null;
      _tapFeedbackDedupeIndex = null;
    });
    _schedulePointerFeedbackSuppression(index);
  }

  void _handlePointerInvalid(int index) {
    if (!widget.enableLineTapFeedback || !mounted) return;
    _schedulePointerFeedbackSuppression(index);
  }

  void _schedulePointerFeedbackSuppression(int index) {
    _pointerFeedbackSuppressions[index]?.cancel();
    _pointerFeedbackSuppressions[index] = Timer(
      _lyricTapFeedbackFallbackWindow,
      () => _pointerFeedbackSuppressions.remove(index)?.cancel(),
    );
  }

  bool _consumePointerFeedbackSuppression(int index) {
    final timer = _pointerFeedbackSuppressions.remove(index);
    if (timer == null) return false;
    timer.cancel();
    return true;
  }

  void _showTapFeedback(int index) {
    if (!widget.enableLineTapFeedback || !mounted) return;
    _tapFeedbackClearTimer?.cancel();
    _tapFeedbackClearTimer = null;
    setState(() => _tapFeedbackIndex = index);
    if (MediaQuery.disableAnimationsOf(context)) {
      _tapFeedbackController.stop(canceled: true);
      _tapFeedbackClearTimer = Timer(_lyricTapFeedbackStaticDuration, () {
        _tapFeedbackClearTimer = null;
        if (mounted) setState(() => _tapFeedbackIndex = null);
      });
      return;
    }
    _tapFeedbackController.forward(from: 0.001);
  }

  void _positionCurrentLine(
    num index,
    double itemExtent, {
    required bool animate,
    Duration duration = const Duration(milliseconds: 460),
    bool deferUntilLayout = true,
  }) {
    if (!_tickersEnabled) return;
    final generation = ++_scrollGeneration;
    Future<void> position() async {
      if (!mounted ||
          generation != _scrollGeneration ||
          !_scrollController.hasClients) {
        return;
      }
      final target = (itemExtent * index).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      if (!animate || MediaQuery.disableAnimationsOf(context)) {
        _scrollController.jumpTo(target);
        return;
      }
      try {
        await _scrollController.animateTo(
          target,
          duration: duration,
          curve: Curves.easeOutCubic,
        );
      } catch (_) {
        // A horizontal page or queue transition may detach the preview.
      }
    }

    if (deferUntilLayout) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(position());
      });
    } else {
      unawaited(position());
    }
  }

  void _beginUserBrowse() {
    _resumeFollowTimer?.cancel();
    _resumeFollowTimer = null;
    _isUserBrowsing = true;
    _userScrollInProgress = true;
    _scrollGeneration++;
  }

  void _endUserBrowse() {
    if (!_userScrollInProgress) return;
    _userScrollInProgress = false;
    _scheduleFollowResume();
  }

  void _scheduleFollowResume() {
    _resumeFollowTimer?.cancel();
    _resumeFollowTimer = Timer(const Duration(seconds: 3), () {
      _resumeFollowTimer = null;
      if (!mounted) return;
      _isUserBrowsing = false;
      final itemExtent = _lastItemExtent;
      if (_latestIndex < 0 || itemExtent == null) return;
      _positionCurrentLine(
        _latestIndex,
        itemExtent,
        animate: true,
        duration: const Duration(milliseconds: 300),
        deferUntilLayout: false,
      );
    });
  }

  void _seekToLine(int index, List<LyricLine> lyrics, double itemExtent) {
    if (index < 0 || index >= lyrics.length) return;
    _resumeFollowTimer?.cancel();
    _isUserBrowsing = true;
    _userScrollInProgress = false;
    widget.onSeekRequested(lyrics[index].startTime);
    _positionCurrentLine(
      index,
      itemExtent,
      animate: true,
      duration: const Duration(milliseconds: 280),
      deferUntilLayout: false,
    );
    _scheduleFollowResume();
  }

  bool _handleUserScrollNotification(UserScrollNotification notification) {
    if (notification.direction != ScrollDirection.idle) {
      _beginUserBrowse();
    } else {
      _endUserBrowse();
    }
    return false;
  }

  void _resetUserBrowse() {
    _resumeFollowTimer?.cancel();
    _resumeFollowTimer = null;
    _isUserBrowsing = false;
    _userScrollInProgress = false;
    _scrollGeneration++;
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = ref.watch(
      lyricControllerProvider.select((state) => state.displayLyrics),
    );
    ref.listen<int>(currentLyricIndexProvider, (_, index) {
      _latestIndex = index;
      if (_tickersEnabled) setState(() {});
    });
    final index = ref.read(currentLyricIndexProvider);
    final settings = ref.watch(playerLyricSettingsProvider);
    if (lyrics.isEmpty) {
      _clearTapFeedbackState(notify: false);
      _latestIndex = -1;
      _lastIndex = null;
      _lyricsSignature = null;
      _lastItemExtent = null;
      if (_isUserBrowsing || _resumeFollowTimer != null) {
        _resetUserBrowse();
      }
      return SizedBox(
        key: ValueKey('compact-lyric-preview-${widget.lineCount}-lines'),
        height: widget.compact ? 70 : (widget.lineCount == 5 ? 144 : 100),
      );
    }

    final signature = Object.hash(
      lyrics.length,
      lyrics.first.startTime,
      lyrics.first.text,
      lyrics.last.startTime,
      lyrics.last.text,
    );
    final sourceChanged = signature != _lyricsSignature;
    if (sourceChanged) {
      _resetUserBrowse();
      _clearTapFeedbackState(notify: false);
      _lyricsSignature = signature;
      _lastIndex = null;
    }
    _latestIndex = index;
    final edgeInset = 1 / MediaQuery.devicePixelRatioOf(context);

    Widget buildPreview(
      double previewHeight,
      double itemExtent,
      double widthScale,
    ) => Semantics(
      container: true,
      label: index >= 0 && index < lyrics.length ? lyrics[index].text : null,
      child: SizedBox(
        key: ValueKey('compact-lyric-preview-${widget.lineCount}-lines'),
        height: previewHeight,
        child: ClipRect(
          child: RepaintBoundary(
            child: ShaderMask(
              key: const ValueKey('compact-lyric-edge-fade-mask'),
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) => playerLyricEdgeFadeGradient(
                bounds,
                topFadeExtent: _lyricPreviewFadeExtent,
                bottomFadeExtent: _lyricPreviewFadeExtent,
              ).createShader(bounds),
              // Fractional mask edges can leave the last pixel unmasked.
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: edgeInset),
                child: NotificationListener<UserScrollNotification>(
                  onNotification: _handleUserScrollNotification,
                  child: ListView.builder(
                    key: const ValueKey('compact-lyric-scroll-list'),
                    controller: _scrollController,
                    physics: const ClampingScrollPhysics(),
                    itemExtent: itemExtent,
                    scrollCacheExtent: ScrollCacheExtent.pixels(previewHeight),
                    padding: EdgeInsets.symmetric(
                      vertical: math.max(
                        0.0,
                        (previewHeight - itemExtent) / 2 - edgeInset,
                      ),
                    ),
                    itemCount: lyrics.length,
                    itemBuilder: (context, lyricIndex) {
                      final distance = (lyricIndex - index).abs();
                      final active = distance == 0;
                      final lyricRow = Listener(
                        behavior: widget.enableLineTapFeedback
                            ? HitTestBehavior.opaque
                            : HitTestBehavior.deferToChild,
                        onPointerDown: widget.enableLineTapFeedback
                            ? (event) => _pointerTracker.handlePointerDown(
                                event,
                                lyricIndex,
                              )
                            : null,
                        onPointerMove: widget.enableLineTapFeedback
                            ? _pointerTracker.handlePointerMove
                            : null,
                        onPointerUp: widget.enableLineTapFeedback
                            ? _pointerTracker.handlePointerUp
                            : null,
                        onPointerCancel: widget.enableLineTapFeedback
                            ? _pointerTracker.handlePointerCancel
                            : null,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            key: ValueKey('compact-lyric-line-$lyricIndex'),
                            overlayColor: widget.enableLineTapFeedback
                                ? const WidgetStatePropertyAll(
                                    Colors.transparent,
                                  )
                                : null,
                            splashFactory: widget.enableLineTapFeedback
                                ? NoSplash.splashFactory
                                : null,
                            onTap: () {
                              if (!_consumePointerFeedbackSuppression(
                                lyricIndex,
                              )) {
                                _showTapFeedback(lyricIndex);
                              }
                              _seekToLine(lyricIndex, lyrics, itemExtent);
                            },
                            onDoubleTap: widget.onLineDoubleTap == null
                                ? null
                                : () {
                                    if (!_consumePointerFeedbackSuppression(
                                          lyricIndex,
                                        ) &&
                                        _tapFeedbackIndex != lyricIndex) {
                                      _showTapFeedback(lyricIndex);
                                    }
                                    widget.onLineDoubleTap!.call();
                                  },
                            child: Center(
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: widget.textHorizontalPadding,
                                ),
                                child: _PreviewLine(
                                  text: lyrics[lyricIndex].text,
                                  fontSize: active
                                      ? settings.smallFontSize * widthScale +
                                            (widget.compact ? 0 : 1)
                                      : settings.smallFontSize * widthScale - 1,
                                  lineHeight: settings.smallLineHeight,
                                  opacity: active
                                      ? 1
                                      : (distance == 1 ? 0.56 : 0.36),
                                  fontWeight: active
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                  maxLines: 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                      final content = widget.enableLineTapFeedback
                          ? _buildLyricTapFeedbackSurface(
                              opacity: _tapFeedbackOpacity,
                              active: _tapFeedbackIndex == lyricIndex,
                              reducedMotion: MediaQuery.disableAnimationsOf(
                                context,
                              ),
                              color: Theme.of(context).colorScheme.onSurface,
                              keyValue:
                                  'compact-lyric-tap-feedback-$lyricIndex',
                              child: lyricRow,
                            )
                          : lyricRow;
                      return ListenableBuilder(
                        listenable: _scrollController,
                        child: Semantics(
                          button: true,
                          selected: active,
                          child: content,
                        ),
                        builder: (context, child) {
                          final center = _scrollController.hasClients
                              ? _scrollController.offset / itemExtent
                              : math.max(0, index).toDouble();
                          final visibility =
                              (widget.lineCount / 2 -
                                      (lyricIndex - center).abs())
                                  .clamp(0.0, 1.0)
                                  .toDouble();
                          return Offstage(
                            offstage: visibility == 0,
                            child: Opacity(opacity: visibility, child: child),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : _lyricAdaptiveBaseWidth;
        final widthScale = _lyricWidthScale(width);
        final activeFontSize =
            settings.smallFontSize * widthScale + (widget.compact ? 0 : 1);
        final itemExtent = _lyricPreviewItemExtent(
          activeFontSize,
          settings.smallLineHeight,
          MediaQuery.textScalerOf(context),
        );
        final visibleLineCount = _visiblePreviewLineCount(
          widget.lineCount,
          constraints.maxHeight,
          itemExtent,
        );
        final desiredHeight =
            visibleLineCount * itemExtent + _lyricPreviewFadeExtent * 2;
        final previousItemExtent = _lastItemExtent;
        final itemExtentChanged = previousItemExtent != itemExtent;
        if (itemExtentChanged &&
            previousItemExtent != null &&
            _isUserBrowsing &&
            _scrollController.hasClients) {
          _positionCurrentLine(
            _scrollController.offset / previousItemExtent,
            itemExtent,
            animate: false,
          );
        }
        _lastItemExtent = itemExtent;
        if (index >= 0 &&
            (index != _lastIndex || sourceChanged || itemExtentChanged)) {
          final animate = _lastIndex != null && !sourceChanged;
          _lastIndex = index;
          if (!_isUserBrowsing) {
            _positionCurrentLine(index, itemExtent, animate: animate);
          }
        }
        return buildPreview(
          constraints.constrainHeight(desiredHeight),
          itemExtent,
          widthScale,
        );
      },
    );
  }
}

int _visiblePreviewLineCount(
  int requestedLineCount,
  double maxHeight,
  double itemExtent,
) {
  if (requestedLineCount == 5 &&
      maxHeight >= 5 * itemExtent + _lyricPreviewFadeExtent * 2) {
    return 5;
  }
  if (requestedLineCount >= 3 &&
      maxHeight >= 3 * itemExtent + _lyricPreviewFadeExtent * 2) {
    return 3;
  }
  return 1;
}

class _PreviewLine extends StatelessWidget {
  const _PreviewLine({
    required this.text,
    required this.fontSize,
    required this.lineHeight,
    required this.opacity,
    required this.maxLines,
    this.fontWeight = FontWeight.w600,
  });

  final String text;
  final double fontSize;
  final double lineHeight;
  final double opacity;
  final int maxLines;
  final FontWeight fontWeight;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.isEmpty ? ' ' : text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: Theme.of(
          context,
        ).colorScheme.onSurface.withValues(alpha: opacity),
        fontSize: fontSize,
        fontWeight: fontWeight,
        height: lineHeight,
      ),
    );
  }
}

@immutable
class LyricSearchMatch {
  const LyricSearchMatch({
    required this.lineIndex,
    required this.start,
    required this.end,
  });

  final int lineIndex;
  final int start;
  final int end;
}

List<LyricSearchMatch> findLyricSearchMatches(
  List<LyricLine> lyrics,
  String rawQuery,
) {
  final query = rawQuery.trim();
  if (query.isEmpty) return const [];
  final expression = RegExp(
    RegExp.escape(query),
    caseSensitive: false,
    unicode: true,
  );
  final matches = <LyricSearchMatch>[];
  for (var lineIndex = 0; lineIndex < lyrics.length; lineIndex++) {
    for (final match in expression.allMatches(lyrics[lineIndex].text)) {
      matches.add(
        LyricSearchMatch(
          lineIndex: lineIndex,
          start: match.start,
          end: match.end,
        ),
      );
    }
  }
  return matches;
}

class _LyricLineLayout {
  const _LyricLineLayout({required this.extent, required this.matchCenterY});

  final double extent;
  final double matchCenterY;
}

class _LyricLineLayoutEntry {
  const _LyricLineLayoutEntry({
    required this.active,
    required this.selectedStart,
    required this.selectedEnd,
    required this.layout,
  });

  final bool active;
  final int? selectedStart;
  final int? selectedEnd;
  final _LyricLineLayout layout;

  bool matches(bool isActive, LyricSearchMatch? selectedMatch) {
    return active == isActive &&
        selectedStart == selectedMatch?.start &&
        selectedEnd == selectedMatch?.end;
  }
}

/// Measures the same spans rendered by the lyric list and retains one current
/// layout per line. This makes a distant offset deterministic without eagerly
/// building every intervening widget.
class _LyricLayoutIndex {
  _LyricLayoutIndex({
    required this.lyrics,
    required this.query,
    required this.activeStyle,
    required this.inactiveStyle,
    required this.colors,
    required this.textWidth,
    required this.textScaler,
    required this.textDirection,
    required this.locale,
  });

  static const double itemVerticalPadding = 20;

  final List<LyricLine> lyrics;
  final String query;
  final TextStyle activeStyle;
  final TextStyle inactiveStyle;
  final ColorScheme colors;
  final double textWidth;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final Locale? locale;
  final Map<int, _LyricLineLayoutEntry> _entries = {};

  double get activeTextScale =>
      _lyricActiveTextScale(activeStyle, inactiveStyle, textScaler);

  _LyricLineLayout layoutFor(
    int index, {
    required bool active,
    LyricSearchMatch? selectedMatch,
  }) {
    final cached = _entries[index];
    if (cached != null && cached.matches(active, selectedMatch)) {
      return cached.layout;
    }
    final text = lyrics[index].text;
    final activeScale = activeTextScale;
    final paintScale = active ? activeScale : _lyricSpringScaleRest;
    final painter = TextPainter(
      text: _highlightedLyricSpan(
        text: text,
        query: query,
        selectedMatch: selectedMatch,
        style: inactiveStyle,
        colors: colors,
      ),
      textAlign: TextAlign.center,
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
    )..layout(maxWidth: textWidth);
    var matchCenterY = painter.height / 2;
    if (selectedMatch != null &&
        selectedMatch.start >= 0 &&
        selectedMatch.end <= text.length &&
        selectedMatch.start < selectedMatch.end) {
      final boxes = painter.getBoxesForSelection(
        TextSelection(
          baseOffset: selectedMatch.start,
          extentOffset: selectedMatch.end,
        ),
      );
      if (boxes.isNotEmpty) {
        var top = boxes.first.top;
        var bottom = boxes.first.bottom;
        for (final box in boxes.skip(1)) {
          top = math.min(top, box.top);
          bottom = math.max(bottom, box.bottom);
        }
        matchCenterY = (top + bottom) / 2;
      }
    }
    final contentHeight = painter.height;
    final maxPaintScale = math.max(
      1.0,
      math.max(activeScale, _lyricSpringScaleRest),
    );
    final layout = _LyricLineLayout(
      extent: contentHeight * maxPaintScale + itemVerticalPadding,
      matchCenterY:
          (contentHeight * maxPaintScale + itemVerticalPadding) / 2 +
          (matchCenterY - contentHeight / 2) * paintScale,
    );
    _entries[index] = _LyricLineLayoutEntry(
      active: active,
      selectedStart: selectedMatch?.start,
      selectedEnd: selectedMatch?.end,
      layout: layout,
    );
    return layout;
  }

  double extentFor(
    int index, {
    required int currentIndex,
    required LyricSearchMatch? selectedMatch,
  }) {
    return layoutFor(
      index,
      active: index == currentIndex,
      selectedMatch: selectedMatch?.lineIndex == index ? selectedMatch : null,
    ).extent;
  }

  double offsetBefore(
    int targetIndex, {
    required int currentIndex,
    required LyricSearchMatch? selectedMatch,
  }) {
    var offset = 0.0;
    final end = targetIndex.clamp(0, lyrics.length);
    for (var index = 0; index < end; index++) {
      offset += extentFor(
        index,
        currentIndex: currentIndex,
        selectedMatch: selectedMatch,
      );
    }
    return offset;
  }
}

class FullLyricDisplayController {
  _FullLyricDisplayState? _state;

  void _attach(_FullLyricDisplayState state) => _state = state;

  void _detach(_FullLyricDisplayState state) {
    if (identical(_state, state)) _state = null;
  }

  void centerOnMatch(
    LyricSearchMatch match, {
    bool animate = true,
    required double Function() visibleBottomInset,
  }) {
    _state?._scrollToMatch(
      match,
      animate: animate,
      visibleBottomInset: visibleBottomInset,
    );
  }

  void centerCurrentIfOutside({
    bool animate = true,
    required double visibleBottomInset,
  }) {
    _state?._centerCurrentIfOutside(
      animate: animate,
      visibleBottomInset: visibleBottomInset,
    );
  }
}

class FullLyricDisplay extends ConsumerStatefulWidget {
  const FullLyricDisplay({
    super.key,
    this.seekingPosition,
    this.seekingPositionListenable,
    this.isActive = true,
    this.isPortrait = false,
    this.isLocked = false,
    this.onLongPress,
    this.controller,
    this.scrollController,
    this.suspendAutoScroll = false,
    this.searchMode = false,
    this.searchQuery = '',
    this.layoutSearchQuery,
    this.selectedSearchMatch,
    this.playbackAnchorFraction = 0.4,
    this.contentWidth,
    this.showPlaybackLineControls = false,
    this.visibleBottomInset = 0,
    this.snapOnAutoScrollResume = true,
    this.snapToCurrentOnFirstLayout = true,
    this.onSeekRequested,
    this.onLineDoubleTap,
    this.enableLineTapFeedback = false,
  }) : assert(playbackAnchorFraction > 0 && playbackAnchorFraction < 1);

  final Duration? seekingPosition;
  final ValueListenable<PlayerSeekPreview?>? seekingPositionListenable;
  final bool isActive;
  final bool isPortrait;
  final bool isLocked;
  final VoidCallback? onLongPress;
  final FullLyricDisplayController? controller;
  final ScrollController? scrollController;
  final bool suspendAutoScroll;
  final bool searchMode;
  final String searchQuery;
  final String? layoutSearchQuery;
  final LyricSearchMatch? selectedSearchMatch;
  final double playbackAnchorFraction;
  final double? contentWidth;
  final bool showPlaybackLineControls;
  final double visibleBottomInset;
  final bool snapOnAutoScrollResume;
  final bool snapToCurrentOnFirstLayout;
  final ValueChanged<Duration>? onSeekRequested;
  final VoidCallback? onLineDoubleTap;
  final bool enableLineTapFeedback;

  @override
  ConsumerState<FullLyricDisplay> createState() => _FullLyricDisplayState();
}

typedef _LyricBrowseAnchor = ({
  List<LyricLine> lyrics,
  int lineIndex,
  double fraction,
});

class _FullLyricDisplayState extends ConsumerState<FullLyricDisplay>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final ScrollController _ownedScrollController = ScrollController();
  ScrollController get _scrollController =>
      widget.scrollController ?? _ownedScrollController;
  final GlobalKey _viewportKey = GlobalKey();
  final Map<int, GlobalKey> _itemKeys = {};
  final Map<int, GlobalKey> _textKeys = {};
  late final _LyricPointerTracker _pointerTracker;
  late final AnimationController _tapFeedbackController;
  late final Animation<double> _tapFeedbackOpacity;
  late final Ticker _lyricMotionTicker;
  final ValueNotifier<int> _lyricMotionFrame = ValueNotifier(0);
  final Map<int, _LyricSpringMotion> _lyricMotion = {};
  final Map<int, _LyricEmphasisMotion> _lyricEmphasisMotion = {};
  final Map<int, _LyricSpringSample> _frozenLyricMotion = {};
  final Map<int, double> _lyricMotionBaseY = {};
  final Map<int, double> _pendingLyricY = {};
  final Map<int, double> _pendingLyricTextY = {};
  Duration _lyricMotionElapsed = Duration.zero;
  Duration? _lastLyricMotionTick;
  _LyricScrollMotion? _lyricScrollMotion;
  int? _scrollSpringTargetIndex;
  int? _scrollSpringOriginIndex;
  final Set<int> _pendingScrollSpringRows = {};
  final Set<int> _retainedScrollSpringRows = {};
  final ValueNotifier<int> _retainedScrollSpringRowsFrame = ValueNotifier(0);
  bool _tickerModeEnabled = true;
  bool _appLifecycleVisible = true;
  bool _reducedMotion = false;
  int? _currentLyricIndex;
  Duration? _lastSeekingPosition;
  int? _pendingTappedIndex;
  int? _pendingTapOriginIndex;
  bool _pendingTapAcknowledged = false;
  bool _autoScroll = true;
  bool _userScrollInProgress = false;
  int? _lyricScrollHoldPointer;
  bool _checkedStoredScrollOffset = false;
  bool _hasStoredScrollOffset = false;
  bool _restoreFollowing = false;
  _LyricBrowseAnchor? _restoredBrowseAnchor;
  PageStorageBucket? _pageStorageBucket;
  Timer? _resumeAutoScrollTimer;
  Timer? _tapFeedbackClearTimer;
  Timer? _tapFeedbackDedupeTimer;
  final Map<int, Timer> _pointerFeedbackSuppressions = {};
  int _scrollRequestGeneration = 0;
  int? _pendingLyricEmphasisFromIndex;
  ({int index, int originIndex})? _pendingDiscontinuity;
  List<LyricLine>? _lastDisplayLyrics;
  String? _lastTrackKey;
  PlayerLyricSpringPreset _springPreset = PlayerLyricSpringPreset.defaultPreset;
  int? _layoutFingerprint;
  _LyricLayoutIndex? _layoutIndex;
  double _effectiveTopPadding = 0;
  int _layoutCurrentIndex = -1;
  LyricSearchMatch? _layoutSelectedMatch;
  int? _tapFeedbackIndex;
  int? _tapFeedbackDedupeIndex;

  Object? get _scrollStorageIdentifier => widget.key is PageStorageKey
      ? ('full-lyric-scroll-anchor', widget.key)
      : null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _appLifecycleVisible =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    _pointerTracker = _LyricPointerTracker(
      onTap: _handlePointerTap,
      onInvalid: _handlePointerInvalid,
    );
    _tapFeedbackController = AnimationController(
      vsync: this,
      duration: _lyricTapFeedbackDuration,
    )..addStatusListener(_handleTapFeedbackStatus);
    _tapFeedbackOpacity = _lyricTapFeedbackOpacity().animate(
      _tapFeedbackController,
    );
    _lyricMotionTicker = createTicker(_handleLyricMotionTick);
    widget.controller?._attach(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    if (_tickerModeEnabled != tickerModeEnabled) {
      _tickerModeEnabled = tickerModeEnabled;
      if (tickerModeEnabled) {
        _scheduleLyricResync();
      } else {
        _scrollRequestGeneration++;
        _clearLyricMotion(notify: false);
        _pendingTappedIndex = null;
        _pendingTapOriginIndex = null;
        _pendingTapAcknowledged = false;
      }
    }
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion != reducedMotion) {
      _reducedMotion = reducedMotion;
      if (reducedMotion) {
        final scrollTarget = _scrollSpringTargetIndex;
        final playbackIndex = ref.read(currentLyricIndexProvider);
        final index =
            _pendingTappedIndex ??
            (playbackIndex >= 0 ? playbackIndex : scrollTarget);
        _scrollRequestGeneration++;
        _clearLyricMotion(notify: false);
        if (scrollTarget != null && index != null && index >= 0) {
          final target = _layoutTargetForLine(
            index,
            widget.visibleBottomInset,
            clampToBounds: false,
          );
          if (target != null && _scrollController.hasClients) {
            _scrollController.jumpTo(target);
          }
        }
      }
    }
    if (_checkedStoredScrollOffset) return;
    _checkedStoredScrollOffset = true;
    _pageStorageBucket = PageStorage.maybeOf(context);
    _hasStoredScrollOffset = _pageStorageBucket?.readState(context) is double;
    final identifier = _scrollStorageIdentifier;
    if (_hasStoredScrollOffset && identifier != null) {
      final stored = _pageStorageBucket?.readState(
        context,
        identifier: identifier,
      );
      _restoreFollowing = stored == true;
      _restoredBrowseAnchor = stored is _LyricBrowseAnchor ? stored : null;
    }
  }

  @override
  void deactivate() {
    final identifier = _scrollStorageIdentifier;
    final index = _currentLyricIndex;
    if (identifier != null && _pageStorageBucket != null) {
      final target = _autoScroll && !widget.suspendAutoScroll && index != null
          ? _layoutTargetForLine(index, widget.visibleBottomInset)
          : null;
      final following =
          target != null &&
          ((target - _scrollController.position.pixels).abs() <= 2.1 ||
              _scrollController.position.isScrollingNotifier.value ||
              _scrollSpringTargetIndex != null);
      _pageStorageBucket!.writeState(
        context,
        following ? true : _captureBrowseAnchor(),
        identifier: identifier,
      );
    }
    super.deactivate();
  }

  @override
  void didUpdateWidget(covariant FullLyricDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (oldWidget.enableLineTapFeedback && !widget.enableLineTapFeedback) {
      _clearTapFeedbackState(notify: false);
    }
    if (oldWidget.isActive && !widget.isActive) {
      _resumeAutoScrollTimer?.cancel();
      _resumeAutoScrollTimer = null;
      _userScrollInProgress = false;
      _autoScroll = true;
      _pendingTappedIndex = null;
      _pendingTapOriginIndex = null;
      _pendingTapAcknowledged = false;
      _scrollRequestGeneration++;
      _clearLyricMotion(notify: false);
      _clearTapFeedbackState(notify: false);
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.pixels);
      }
    }
    if (!oldWidget.isActive && widget.isActive) _scheduleLyricResync();
    if (!oldWidget.isLocked && widget.isLocked) {
      _clearTapFeedbackState(notify: false);
    }
    if (!oldWidget.suspendAutoScroll && widget.suspendAutoScroll) {
      _scrollRequestGeneration++;
      _clearLyricMotion(notify: false);
      _pendingTappedIndex = null;
      _pendingTapOriginIndex = null;
      _pendingTapAcknowledged = false;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.pixels);
      }
    }
    if ((!oldWidget.searchMode && widget.searchMode) ||
        oldWidget.selectedSearchMatch != widget.selectedSearchMatch) {
      _scrollRequestGeneration++;
      _clearLyricMotion(notify: false);
      _pendingTappedIndex = null;
      _pendingTapOriginIndex = null;
      _pendingTapAcknowledged = false;
    }
    if (oldWidget.suspendAutoScroll &&
        !widget.suspendAutoScroll &&
        _autoScroll) {
      final index = _currentLyricIndex;
      if (widget.snapOnAutoScrollResume && index != null && index >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToLyric(
            index,
            animate: false,
            force: true,
            ignoreAutoScroll: true,
          );
        });
      }
    }
    final selectedMatch = widget.selectedSearchMatch;
    if (oldWidget.visibleBottomInset != widget.visibleBottomInset &&
        selectedMatch != null) {
      final match = selectedMatch;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.selectedSearchMatch != match) return;
        _scrollToMatch(
          match,
          animate: false,
          visibleBottomInset: () => widget.visibleBottomInset,
        );
      });
    } else if (oldWidget.visibleBottomInset != widget.visibleBottomInset &&
        _scrollSpringTargetIndex != null) {
      final request = _scrollRequestGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || request != _scrollRequestGeneration) return;
        final index =
            _pendingTappedIndex ?? ref.read(currentLyricIndexProvider);
        if (index != null && index >= 0) {
          _startLyricScrollSpring(
            index,
            stagger: false,
            previousIndex: _scrollSpringOriginIndex,
            request: request,
          );
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed;
    if (_appLifecycleVisible == visible) return;
    _appLifecycleVisible = visible;
    if (visible) {
      _scheduleLyricResync();
    } else {
      _scrollRequestGeneration++;
      _clearLyricMotion();
      _pendingTappedIndex = null;
      _pendingTapOriginIndex = null;
      _pendingTapAcknowledged = false;
    }
  }

  void _scheduleLyricResync() {
    // The next build owns following; another jump here would use stale layout.
    _currentLyricIndex = null;
    _pendingTappedIndex = null;
    _pendingTapOriginIndex = null;
    _pendingTapAcknowledged = false;
    _clearLyricMotion(notify: false);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_tickerModeEnabled ||
          !_appLifecycleVisible ||
          !widget.isActive ||
          !_scrollController.hasClients) {
        return;
      }
      final match = widget.selectedSearchMatch;
      if (match != null) {
        _scrollToMatch(
          match,
          animate: false,
          visibleBottomInset: () => widget.visibleBottomInset,
        );
        return;
      }
    });
  }

  @override
  void dispose() {
    _scrollRequestGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?._detach(this);
    _resumeAutoScrollTimer?.cancel();
    _clearTapFeedbackState(notify: false);
    _lyricMotionTicker.dispose();
    _lyricMotionFrame.dispose();
    _retainedScrollSpringRowsFrame.dispose();
    _tapFeedbackController.dispose();
    if (widget.scrollController == null) _ownedScrollController.dispose();
    _itemKeys.clear();
    _textKeys.clear();
    super.dispose();
  }

  double get _lyricMotionSeconds =>
      _lyricMotionElapsed.inMicroseconds / Duration.microsecondsPerSecond;

  void _handleLyricMotionTick(Duration elapsed) {
    final previous = _lastLyricMotionTick;
    _lyricMotionElapsed += previous == null ? elapsed : elapsed - previous;
    _lastLyricMotionTick = elapsed;
    final now = _lyricMotionSeconds;
    _lyricEmphasisMotion.removeWhere((index, motion) {
      return motion.sample(now).done;
    });
    _lyricMotion.removeWhere((index, motion) {
      if (!motion.sample(now).done) return false;
      if (!_retainedScrollSpringRows.contains(index)) {
        _lyricMotionBaseY.remove(index);
      }
      return true;
    });
    final scrollMotion = _lyricScrollMotion;
    if (scrollMotion != null) {
      if (!_scrollController.hasClients) {
        _lyricScrollMotion = null;
        _scrollSpringTargetIndex = null;
        _scrollSpringOriginIndex = null;
        _pendingScrollSpringRows.clear();
      } else {
        final sample = scrollMotion.sample(now);
        final position = _scrollController.position;
        if (!position.hasContentDimensions) {
          _lyricMotionFrame.value++;
          return;
        }
        final minExtent = math.min(
          position.minScrollExtent,
          scrollMotion.target,
        );
        final maxExtent = math.max(
          position.maxScrollExtent,
          scrollMotion.target,
        );
        final target = sample.position.clamp(minExtent, maxExtent).toDouble();
        if ((target - position.pixels).abs() > 0.1) {
          _scrollController.jumpTo(target);
        }
        final targetOutsideCurrentExtent =
            scrollMotion.target < position.minScrollExtent ||
            scrollMotion.target > position.maxScrollExtent;
        final reachedTarget =
            !targetOutsideCurrentExtent &&
            (position.pixels - scrollMotion.target).abs() <= 0.5;
        if (sample.done && reachedTarget) {
          _lyricScrollMotion = null;
        }
      }
    }
    _lyricMotionFrame.value++;
    if (_lyricMotion.isEmpty &&
        _lyricScrollMotion == null &&
        _lyricEmphasisMotion.isEmpty) {
      _scrollSpringTargetIndex = null;
      _scrollSpringOriginIndex = null;
      _pendingScrollSpringRows.clear();
      if (_frozenLyricMotion.isEmpty) _setRetainedScrollSpringRows(const {});
      _lyricMotionTicker.stop();
      _lastLyricMotionTick = null;
    }
  }

  void _setRetainedScrollSpringRows(Iterable<int> indices) {
    final next = indices.toSet();
    if (next.length == _retainedScrollSpringRows.length &&
        next.every(_retainedScrollSpringRows.contains)) {
      return;
    }
    final previous = _retainedScrollSpringRows.toList();
    _retainedScrollSpringRows
      ..clear()
      ..addAll(next);
    for (final index in previous) {
      if (!next.contains(index) &&
          !_lyricMotion.containsKey(index) &&
          !_frozenLyricMotion.containsKey(index)) {
        _lyricMotionBaseY.remove(index);
      }
    }
    _retainedScrollSpringRowsFrame.value++;
  }

  void _startLyricMotionTicker() {
    if ((_lyricMotion.isEmpty &&
            _lyricScrollMotion == null &&
            _lyricEmphasisMotion.isEmpty) ||
        _lyricMotionTicker.isActive) {
      return;
    }
    _lastLyricMotionTick = null;
    _lyricMotionTicker.start();
  }

  void _clearLyricMotion({bool notify = true, bool preserveEmphasis = false}) {
    _lyricMotionTicker.stop();
    _lastLyricMotionTick = null;
    _lyricScrollMotion = null;
    _scrollSpringTargetIndex = null;
    _scrollSpringOriginIndex = null;
    _pendingScrollSpringRows.clear();
    _lyricMotion.clear();
    if (!preserveEmphasis) _lyricEmphasisMotion.clear();
    _frozenLyricMotion.clear();
    _lyricMotionBaseY.clear();
    _pendingLyricY.clear();
    _pendingLyricTextY.clear();
    if (!preserveEmphasis) _pendingLyricEmphasisFromIndex = null;
    _setRetainedScrollSpringRows(const {});
    if (preserveEmphasis) _startLyricMotionTicker();
    if (notify) _lyricMotionFrame.value++;
  }

  bool get _hasLyricMotion =>
      _lyricScrollMotion != null ||
      _lyricMotion.isNotEmpty ||
      _lyricEmphasisMotion.isNotEmpty ||
      _frozenLyricMotion.isNotEmpty ||
      _pendingLyricY.isNotEmpty ||
      _pendingLyricTextY.isNotEmpty;

  void _freezeLyricMotion() {
    final indices = <int>{
      ..._lyricMotion.keys,
      ..._frozenLyricMotion.keys,
      ..._retainedScrollSpringRows,
      ..._pendingLyricY.keys,
    };
    for (final index in indices) {
      final contentCenter = _lyricContentCenter(index);
      final visibleY = _lyricMotionCenter(index, contentCenter);
      if (_scrollController.hasClients) {
        _lyricMotionBaseY[index] =
            contentCenter - _scrollController.position.pixels;
      }
      _frozenLyricMotion[index] = (
        y: visibleY,
        velocityY: 0,
        moving: false,
        done: true,
      );
    }
    _lyricScrollMotion = null;
    _scrollSpringTargetIndex = null;
    _scrollSpringOriginIndex = null;
    _pendingScrollSpringRows.clear();
    _lyricMotion.clear();
    _pendingLyricY.clear();
    _pendingLyricTextY.clear();
    if (_lyricEmphasisMotion.isEmpty) {
      _lyricMotionTicker.stop();
      _lastLyricMotionTick = null;
    } else {
      _startLyricMotionTicker();
    }
    _lyricMotionFrame.value++;
  }

  Map<int, double> _captureLyricCenters() {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    final centers = <int, double>{};
    for (final entry in _itemKeys.entries) {
      if (_lyricMotion.containsKey(entry.key) ||
          _frozenLyricMotion.containsKey(entry.key) ||
          _retainedScrollSpringRows.contains(entry.key) ||
          _pendingLyricY.containsKey(entry.key)) {
        centers[entry.key] = _lyricMotionCenter(
          entry.key,
          _lyricContentCenter(entry.key),
        );
        continue;
      }
      final row = entry.value.currentContext?.findRenderObject();
      if (viewport is RenderBox &&
          row is RenderBox &&
          viewport.attached &&
          row.attached) {
        centers[entry.key] = row
            .localToGlobal(Offset(0, row.size.height / 2), ancestor: viewport)
            .dy;
      }
    }
    return centers;
  }

  Map<int, double> _captureLyricTextCenters() {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached) return const {};
    final centers = <int, double>{};
    for (final entry in _textKeys.entries) {
      final text = entry.value.currentContext?.findRenderObject();
      if (text is! RenderBox || !text.attached) continue;
      centers[entry.key] = text
          .localToGlobal(Offset(0, text.size.height / 2), ancestor: viewport)
          .dy;
    }
    return centers;
  }

  void _handlePositionDiscontinuity(
    PositionDiscontinuity discontinuity, {
    required List<LyricLine> lyrics,
    required String? trackKey,
    required Duration? seekingPosition,
  }) {
    final pendingTapIndex = _pendingTappedIndex;
    if (discontinuity.reason == PositionDiscontinuityReason.seek &&
        pendingTapIndex != null &&
        !_pendingTapAcknowledged &&
        pendingTapIndex >= 0 &&
        pendingTapIndex < lyrics.length &&
        lyrics[pendingTapIndex].startTime ==
            discontinuity.event.updatePosition) {
      _pendingTapAcknowledged = true;
      return;
    }
    _scrollRequestGeneration++;
    _clearLyricMotion();
    _pendingTappedIndex = null;
    _pendingTapOriginIndex = null;
    _pendingTapAcknowledged = false;
    _pendingDiscontinuity = null;
    final isSeek = discontinuity.reason == PositionDiscontinuityReason.seek;
    final isLoop =
        discontinuity.reason == PositionDiscontinuityReason.autoAdvance &&
        discontinuity.previousEvent.currentIndex ==
            discontinuity.event.currentIndex;
    if ((!isSeek && !isLoop) ||
        !_autoScroll ||
        widget.suspendAutoScroll ||
        widget.searchMode ||
        widget.selectedSearchMatch != null ||
        seekingPosition != null) {
      return;
    }
    final index = _indexForPosition(discontinuity.event.updatePosition, lyrics);
    if (index < 0) return;
    final originIndex = ref.read(currentLyricIndexProvider);
    setState(() {
      _pendingDiscontinuity = (index: index, originIndex: originIndex);
    });
    final request = _scrollRequestGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          request != _scrollRequestGeneration ||
          !identical(_lastDisplayLyrics, lyrics) ||
          _lastTrackKey != trackKey ||
          !widget.isActive ||
          !_tickerModeEnabled ||
          !_appLifecycleVisible ||
          !_autoScroll ||
          widget.suspendAutoScroll) {
        return;
      }
      _scrollToLyric(index, animate: false, force: true);
    });
  }

  void _retargetLyricEmphasisMotion(SpringDescription spring) {
    final now = _lyricMotionSeconds;
    for (final entry in _lyricEmphasisMotion.entries.toList()) {
      final motion = entry.value;
      final sample = motion.sample(now);
      final target = _lyricEmphasisTarget(entry.key, _layoutCurrentIndex);
      if (sample.done &&
          (target.opacity - sample.opacity).abs() < 0.001 &&
          (target.scale - sample.scale).abs() < 0.001) {
        _lyricEmphasisMotion.remove(entry.key);
        continue;
      }
      final progressVelocity = motion.progressVelocity(now);
      final opacityVelocity =
          (motion.targetOpacity - motion.startOpacity) * progressVelocity;
      final scaleVelocity =
          (motion.targetScale - motion.startScale) * progressVelocity;
      final opacityDistance = target.opacity - sample.opacity;
      final scaleDistance = target.scale - sample.scale;
      final velocity = opacityDistance.abs() > 0.001
          ? opacityVelocity / opacityDistance
          : scaleDistance.abs() > 0.001
          ? scaleVelocity / scaleDistance
          : 0.0;
      _lyricEmphasisMotion[entry.key] = _LyricEmphasisMotion(
        startOpacity: sample.opacity,
        targetOpacity: target.opacity,
        startScale: sample.scale,
        targetScale: target.scale,
        startAt: now,
        delay: 0,
        velocity: velocity,
        spring: spring,
      );
    }
  }

  void _retargetLyricMotion(PlayerLyricSpringPreset preset) {
    final now = _lyricMotionSeconds;
    final spring = _lyricPositionSpring(preset);
    _retargetLyricEmphasisMotion(spring);
    final scrollMotion = _lyricScrollMotion;
    if (scrollMotion != null && _scrollController.hasClients) {
      final sample = scrollMotion.sample(now);
      _lyricScrollMotion = _LyricScrollMotion(
        start: _scrollController.position.pixels,
        target: scrollMotion.target,
        velocity: sample.velocity,
        startAt: now,
        spring: spring,
      );
    }
    if (_lyricMotion.isEmpty) {
      _startLyricMotionTicker();
      return;
    }
    for (final entry in _lyricMotion.entries.toList()) {
      final baseY = _lyricMotionBaseY[entry.key];
      if (baseY == null) continue;
      final sample = _visibleLyricSpringSample(entry.key, now);
      if (sample.done) {
        _lyricMotion.remove(entry.key);
        if (!_retainedScrollSpringRows.contains(entry.key)) {
          _lyricMotionBaseY.remove(entry.key);
        }
        continue;
      }
      _lyricMotion[entry.key] = _LyricSpringMotion(
        startY: sample.y,
        targetY: baseY,
        velocityY: sample.velocityY,
        startAt: now,
        delay: 0,
        positionSpring: spring,
      );
    }
    _frozenLyricMotion.clear();
    _startLyricMotionTicker();
  }

  void _startLyricSpringFollow({
    required int index,
    required int previousIndex,
    required int request,
  }) {
    if (!mounted ||
        request != _scrollRequestGeneration ||
        !_shouldAnimateLyrics ||
        !_scrollController.hasClients) {
      return;
    }
    final motionStartTime = _lyricMotionSeconds;
    void startEmphasisOnly() {
      _springPreset = ref.read(playerLyricSettingsProvider).springPreset;
      _startLyricEmphasisTransition(
        targetIndex: index,
        previousIndex: previousIndex,
        indices: _itemKeys.keys,
        spring: _lyricPositionSpring(_springPreset),
        startAt: motionStartTime,
      );
    }

    final viewport = _viewportKey.currentContext?.findRenderObject();
    final layoutIndex = _layoutIndex;
    if (viewport is! RenderBox || layoutIndex == null) {
      startEmphasisOnly();
      _scrollToLyric(
        index,
        animate: false,
        force: true,
        preserveEmphasis: true,
      );
      return;
    }
    final targetBox = _getKeyForIndex(index).currentContext?.findRenderObject();
    if (targetBox is! RenderBox || !targetBox.attached) {
      startEmphasisOnly();
      _scrollToLyric(
        index,
        animate: false,
        force: true,
        preserveEmphasis: true,
      );
      return;
    }
    final visibleHeight = _visibleViewportHeight(widget.visibleBottomInset);
    final targetTop = targetBox
        .localToGlobal(Offset.zero, ancestor: viewport)
        .dy;
    if (targetTop + targetBox.size.height <= 0 || targetTop >= visibleHeight) {
      startEmphasisOnly();
      _scrollToLyric(
        index,
        animate: false,
        force: true,
        preserveEmphasis: true,
      );
      return;
    }
    final now = _lyricMotionSeconds;
    final previousSamples = <int, _LyricSpringSample>{};
    for (final index in _itemKeys.keys) {
      final sample =
          (_lyricMotion.containsKey(index)
              ? _visibleLyricSpringSample(index, now)
              : null) ??
          _frozenLyricMotion[index];
      if (sample == null) continue;
      previousSamples[index] = sample;
    }
    _scrollRequestGeneration++;
    final targetScroll =
        (_lyricContentCenter(index) -
                _playbackAnchorY(widget.visibleBottomInset))
            .clamp(
              _scrollController.position.minScrollExtent,
              _scrollController.position.maxScrollExtent,
            );
    final visibleRows = <({int index, double center})>[];
    for (final entry in _itemKeys.entries) {
      final renderObject = entry.value.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) continue;
      final top = renderObject
          .localToGlobal(Offset.zero, ancestor: viewport)
          .dy;
      final bottom = renderObject
          .localToGlobal(
            Offset(0, renderObject.size.height),
            ancestor: viewport,
          )
          .dy;
      if (bottom <= 0 || top >= visibleHeight) continue;
      visibleRows.add((
        index: entry.key,
        center: renderObject
            .localToGlobal(
              Offset(0, renderObject.size.height / 2),
              ancestor: viewport,
            )
            .dy,
      ));
    }
    if (!visibleRows.any((row) => row.index == index)) {
      startEmphasisOnly();
      _scrollToLyric(
        index,
        animate: false,
        force: true,
        preserveEmphasis: true,
      );
      return;
    }

    visibleRows.sort((left, right) => left.index.compareTo(right.index));
    if (index < previousIndex) {
      visibleRows.setAll(0, visibleRows.reversed);
    }
    final delays = <int, double>{};
    var delayMicros = 0.0;
    var stepMicros = _lyricSpringCascadeStep.inMicroseconds.toDouble();
    var passedTarget = false;
    for (var rowIndex = 0; rowIndex < visibleRows.length; rowIndex++) {
      final row = visibleRows[rowIndex];
      delays[row.index] = delayMicros / Duration.microsecondsPerSecond;
      if (row.index == index) passedTarget = true;
      if (rowIndex + 1 < visibleRows.length) {
        if (passedTarget) stepMicros /= 1.05;
        delayMicros += stepMicros;
      }
    }

    // A selection can change between this frame's build and its callbacks.
    _springPreset = ref.read(playerLyricSettingsProvider).springPreset;
    final spring = _lyricPositionSpring(_springPreset);
    _lyricMotion.clear();
    _frozenLyricMotion.clear();
    _lyricMotionBaseY.clear();
    for (final row in visibleRows) {
      final targetY = _lyricContentCenter(row.index) - targetScroll;
      _lyricMotionBaseY[row.index] = targetY;
      final previousSample = previousSamples[row.index];
      final startY = _startLyricPosition(row, previousSample);
      final startDelay = previousSample?.moving == true
          ? 0.0
          : delays[row.index] ?? 0.0;
      final velocityY = previousSample?.moving == true
          ? previousSample!.velocityY
          : 0.0;
      if ((startY - targetY).abs() < 0.01 && velocityY.abs() < 0.01) {
        continue;
      }
      _lyricMotion[row.index] = _LyricSpringMotion(
        startY: startY,
        targetY: targetY,
        velocityY: velocityY,
        startAt: motionStartTime,
        delay: startDelay,
        positionSpring: spring,
      );
    }
    _pendingLyricY.clear();
    _pendingLyricTextY.clear();
    _startLyricEmphasisTransition(
      targetIndex: index,
      previousIndex: previousIndex,
      indices: visibleRows.map((row) => row.index),
      spring: spring,
      startAt: motionStartTime,
    );
    _lyricMotionFrame.value++;
    if ((targetScroll - _scrollController.position.pixels).abs() > 0.01) {
      _scrollController.jumpTo(targetScroll);
    }
    _startLyricMotionTicker();
  }

  void _startLyricScrollSpring(
    int index, {
    required bool stagger,
    int? previousIndex,
    int? previousEmphasisIndex,
    int? request,
  }) {
    if (!mounted ||
        (request != null && request != _scrollRequestGeneration) ||
        !_scrollController.hasClients) {
      return;
    }
    if (_reducedMotion || MediaQuery.disableAnimationsOf(context)) {
      _pendingLyricEmphasisFromIndex = null;
      _scrollToLyric(
        index,
        animate: false,
        force: true,
        ignoreAutoScroll: true,
      );
      return;
    }
    if (!_shouldAnimateLyrics) return;
    final emphasisOrigin =
        previousEmphasisIndex ??
        _pendingLyricEmphasisFromIndex ??
        _layoutCurrentIndex;
    void startEmphasisOnly() {
      _springPreset = ref.read(playerLyricSettingsProvider).springPreset;
      _startLyricEmphasisTransition(
        targetIndex: index,
        previousIndex: emphasisOrigin,
        indices: _itemKeys.keys,
        spring: _lyricPositionSpring(_springPreset),
        startAt: _lyricMotionSeconds,
      );
    }

    final layoutIndex = _layoutIndex;
    if (layoutIndex == null ||
        index < 0 ||
        index >= layoutIndex.lyrics.length) {
      startEmphasisOnly();
      return;
    }

    final target = _layoutTargetForLine(
      index,
      widget.visibleBottomInset,
      clampToBounds: false,
    );
    if (target == null) {
      startEmphasisOnly();
      return;
    }

    final now = _lyricMotionSeconds;
    final oldScrollMotion = _lyricScrollMotion;
    final oldScrollSample = oldScrollMotion?.sample(now);
    final startScroll = _scrollController.position.pixels;
    final scrollVelocity = oldScrollSample?.velocity ?? 0;
    final originIndex =
        previousIndex ?? _scrollSpringTargetIndex ?? _currentLyricIndex;
    final previousSamples = <int, _LyricSpringSample>{};
    for (final visibleIndex in _itemKeys.keys) {
      final sample =
          (_lyricMotion.containsKey(visibleIndex)
              ? _visibleLyricSpringSample(visibleIndex, now)
              : null) ??
          _frozenLyricMotion[visibleIndex];
      if (sample != null) previousSamples[visibleIndex] = sample;
    }

    final viewport = _viewportKey.currentContext?.findRenderObject();
    final visibleRows = <({int index, double center})>[];
    for (final entry in _itemKeys.entries) {
      final renderObject = entry.value.currentContext?.findRenderObject();
      if (renderObject is! RenderBox ||
          !renderObject.attached ||
          viewport is! RenderBox) {
        continue;
      }
      final top = renderObject
          .localToGlobal(Offset.zero, ancestor: viewport)
          .dy;
      final bottom = renderObject
          .localToGlobal(
            Offset(0, renderObject.size.height),
            ancestor: viewport,
          )
          .dy;
      if (bottom <= 0 ||
          top >= _visibleViewportHeight(widget.visibleBottomInset)) {
        continue;
      }
      visibleRows.add((
        index: entry.key,
        center: renderObject
            .localToGlobal(
              Offset(0, renderObject.size.height / 2),
              ancestor: viewport,
            )
            .dy,
      ));
    }
    visibleRows.sort((left, right) => left.index.compareTo(right.index));
    if (target < startScroll) visibleRows.setAll(0, visibleRows.reversed);

    final delays = <int, double>{};
    var delayMicros = 0.0;
    var stepMicros = _lyricSpringCascadeStep.inMicroseconds.toDouble();
    var passedTarget = false;
    for (var rowIndex = 0; rowIndex < visibleRows.length; rowIndex++) {
      final row = visibleRows[rowIndex];
      delays[row.index] = delayMicros / Duration.microsecondsPerSecond;
      if (row.index == index) passedTarget = true;
      if (rowIndex + 1 < visibleRows.length) {
        if (passedTarget) stepMicros /= 1.05;
        delayMicros += stepMicros;
      }
    }

    _scrollRequestGeneration++;
    _springPreset = ref.read(playerLyricSettingsProvider).springPreset;
    final spring = _lyricPositionSpring(_springPreset);
    _lyricScrollMotion = (target - startScroll).abs() > 0.5
        ? _LyricScrollMotion(
            start: startScroll,
            target: target,
            velocity: scrollVelocity,
            startAt: now,
            spring: spring,
          )
        : null;
    _scrollSpringTargetIndex = index;
    _scrollSpringOriginIndex = originIndex;
    _lyricMotion.clear();
    _frozenLyricMotion.clear();
    _lyricMotionBaseY.clear();
    for (final row in visibleRows) {
      final targetY = _lyricContentCenter(row.index) - target;
      _lyricMotionBaseY[row.index] = targetY;
      final previousSample = previousSamples[row.index];
      final startY = _startLyricPosition(row, previousSample);
      final startDelay = !stagger || previousSample?.moving == true
          ? 0.0
          : delays[row.index] ?? 0.0;
      final velocityY = previousSample?.moving == true
          ? previousSample!.velocityY
          : 0.0;
      if ((startY - targetY).abs() < 0.01 && velocityY.abs() < 0.01) {
        continue;
      }
      _lyricMotion[row.index] = _LyricSpringMotion(
        startY: startY,
        targetY: targetY,
        velocityY: velocityY,
        startAt: now,
        delay: startDelay,
        positionSpring: spring,
      );
    }
    _pendingLyricY.clear();
    _pendingLyricTextY.clear();
    _pendingScrollSpringRows.clear();
    _setRetainedScrollSpringRows(_lyricMotion.keys);
    _startLyricEmphasisTransition(
      targetIndex: index,
      previousIndex: emphasisOrigin,
      indices: visibleRows.map((row) => row.index),
      spring: spring,
      startAt: now,
    );
    _lyricMotionFrame.value++;
    if (_lyricMotion.isNotEmpty ||
        _lyricScrollMotion != null ||
        _lyricEmphasisMotion.isNotEmpty) {
      _startLyricMotionTicker();
    } else {
      _scrollSpringTargetIndex = null;
      _scrollSpringOriginIndex = null;
    }
  }

  void _queueScrollSpringRow(int index) {
    final targetIndex = _scrollSpringTargetIndex;
    final scrollMotion = _lyricScrollMotion;
    if (targetIndex == null ||
        scrollMotion == null ||
        _lyricMotion.containsKey(index) ||
        !_pendingScrollSpringRows.add(index)) {
      return;
    }
    final request = _scrollRequestGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingScrollSpringRows.remove(index);
      if (!mounted ||
          request != _scrollRequestGeneration ||
          targetIndex != _scrollSpringTargetIndex ||
          _lyricMotion.containsKey(index) ||
          !_scrollController.hasClients ||
          _layoutIndex == null) {
        return;
      }
      final motion = _lyricScrollMotion;
      if (motion == null) return;
      final targetY = _lyricContentCenter(index) - motion.target;
      final startY = _lyricContentCenter(index) - motion.start;
      _lyricMotionBaseY[index] = targetY;
      _lyricMotion[index] = _LyricSpringMotion(
        startY: startY,
        targetY: targetY,
        velocityY: -motion.velocity,
        startAt: motion.startAt,
        delay: 0,
        positionSpring: _lyricPositionSpring(_springPreset),
      );
      _startLyricMotionTicker();
    });
  }

  double _lyricContentCenter(int index) {
    final layout = _layoutIndex!;
    return _effectiveTopPadding +
        layout.offsetBefore(
          index,
          currentIndex: _layoutCurrentIndex,
          selectedMatch: _layoutSelectedMatch,
        ) +
        layout.extentFor(
              index,
              currentIndex: _layoutCurrentIndex,
              selectedMatch: _layoutSelectedMatch,
            ) /
            2;
  }

  double _startLyricPosition(
    ({int index, double center}) row,
    _LyricSpringSample? previousSample,
  ) {
    final oldTextCenter = _pendingLyricTextY.remove(row.index);
    final text = _getTextKeyForIndex(
      row.index,
    ).currentContext?.findRenderObject();
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (oldTextCenter != null &&
        text is RenderBox &&
        viewport is RenderBox &&
        text.attached &&
        viewport.attached) {
      final textCenter = text
          .localToGlobal(Offset(0, text.size.height / 2), ancestor: viewport)
          .dy;
      return oldTextCenter - (textCenter - row.center);
    }
    return _pendingLyricY.remove(row.index) ?? previousSample?.y ?? row.center;
  }

  bool get _shouldAnimateLyrics =>
      widget.isActive &&
      !widget.suspendAutoScroll &&
      !widget.searchMode &&
      widget.selectedSearchMatch == null &&
      _autoScroll &&
      _tickerModeEnabled &&
      _appLifecycleVisible &&
      !_reducedMotion;

  _LyricEmphasisValue _lyricEmphasisTarget(int index, int currentIndex) {
    final active = index == currentIndex;
    return (
      opacity: active ? 1 : (index < currentIndex ? 0.24 : 0.34),
      scale: active
          ? (_layoutIndex?.activeTextScale ?? 1)
          : _lyricSpringScaleRest,
    );
  }

  _LyricEmphasisValue _lyricEmphasisValue(int index, {int? currentIndex}) {
    final motion = _lyricEmphasisMotion[index];
    if (motion != null) {
      final sample = motion.sample(_lyricMotionSeconds);
      return (opacity: sample.opacity, scale: sample.scale);
    }
    final fallbackIndex =
        currentIndex ?? _pendingLyricEmphasisFromIndex ?? _layoutCurrentIndex;
    return _lyricEmphasisTarget(index, fallbackIndex);
  }

  void _startLyricEmphasisTransition({
    required int targetIndex,
    required int previousIndex,
    required Iterable<int> indices,
    required SpringDescription spring,
    required double startAt,
  }) {
    final allIndices = <int>{
      if (targetIndex >= 0) targetIndex,
      if (previousIndex >= 0) previousIndex,
      ...indices,
      ..._itemKeys.keys,
      ..._lyricEmphasisMotion.keys,
    };
    final starts = <int, _LyricEmphasisValue>{};
    final previousMotions = Map<int, _LyricEmphasisMotion>.of(
      _lyricEmphasisMotion,
    );
    for (final index in allIndices) {
      starts[index] = _lyricEmphasisValue(index, currentIndex: previousIndex);
    }
    _lyricEmphasisMotion.clear();
    _pendingLyricEmphasisFromIndex = null;
    for (final index in allIndices) {
      final start = starts[index]!;
      final target = _lyricEmphasisTarget(index, targetIndex);
      if ((start.opacity - target.opacity).abs() < 0.001 &&
          (start.scale - target.scale).abs() < 0.001) {
        continue;
      }
      final rowMotion = _lyricMotion[index];
      final rowDistance = rowMotion == null
          ? 0.0
          : rowMotion.targetY - rowMotion.startY;
      final previousMotion = previousMotions[index];
      var velocity = 0.0;
      if (rowMotion != null && rowDistance.abs() > 0.01) {
        velocity = rowMotion.velocityY / rowDistance;
      } else if (previousMotion != null) {
        final progressVelocity = previousMotion.progressVelocity(startAt);
        final opacityVelocity =
            (previousMotion.targetOpacity - previousMotion.startOpacity) *
            progressVelocity;
        final opacityDistance = target.opacity - start.opacity;
        if (opacityDistance.abs() > 0.001) {
          velocity = opacityVelocity / opacityDistance;
        } else {
          final scaleVelocity =
              (previousMotion.targetScale - previousMotion.startScale) *
              progressVelocity;
          final scaleDistance = target.scale - start.scale;
          if (scaleDistance.abs() > 0.001) {
            velocity = scaleVelocity / scaleDistance;
          }
        }
      }
      _lyricEmphasisMotion[index] = _LyricEmphasisMotion(
        startOpacity: start.opacity,
        targetOpacity: target.opacity,
        startScale: start.scale,
        targetScale: target.scale,
        startAt: startAt,
        delay: rowMotion?.delay ?? 0,
        velocity: velocity,
        spring: spring,
      );
    }
    _lyricMotionFrame.value++;
    _startLyricMotionTicker();
  }

  Widget _buildLyricMotion({
    required int index,
    bool translateWithMotion = true,
    required Widget child,
  }) {
    if (_scrollSpringTargetIndex != null && _lyricScrollMotion != null) {
      _queueScrollSpringRow(index);
    }
    final contentCenter = _lyricContentCenter(index);
    return AnimatedBuilder(
      animation: _lyricMotionFrame,
      child: child,
      builder: (context, child) {
        final naturalY = contentCenter - _scrollController.position.pixels;
        final motionY = _lyricMotionCenter(index, contentCenter);
        final offset = translateWithMotion ? motionY - naturalY : 0.0;
        return Transform.translate(
          offset: Offset(0, offset),
          transformHitTests: true,
          child: child,
        );
      },
    );
  }

  double _lyricMotionCenter(int index, double contentCenter) {
    final position = _scrollController.position;
    final naturalY = contentCenter - position.pixels;
    final pendingY = _pendingLyricY[index];
    final sample = _lyricMotion[index]?.sample(_lyricMotionSeconds);
    final frozen = _frozenLyricMotion[index];
    final baseY = _lyricMotionBaseY[index];
    final retained = _retainedScrollSpringRows.contains(index) && baseY != null;
    if (pendingY == null && sample == null && frozen == null && !retained) {
      return naturalY;
    }
    final center =
        pendingY ??
        (sample != null
            ? sample.y
            : frozen != null && baseY != null
            ? naturalY + frozen.y - baseY
            : retained
            ? baseY
            : naturalY);
    if (!position.hasContentDimensions) return center;
    final scrollTarget = _lyricScrollMotion?.target;
    return center
        .clamp(
          contentCenter -
              (scrollTarget == null
                  ? position.maxScrollExtent
                  : math.max(position.maxScrollExtent, scrollTarget)),
          contentCenter -
              (scrollTarget == null
                  ? position.minScrollExtent
                  : math.min(position.minScrollExtent, scrollTarget)),
        )
        .toDouble();
  }

  _LyricSpringSample _visibleLyricSpringSample(int index, double now) {
    final sample = _lyricMotion[index]!.sample(now);
    final center = _lyricMotionCenter(index, _lyricContentCenter(index));
    final isAtScrollBoundary = (center - sample.y).abs() > 0.01;
    return (
      y: center,
      velocityY: isAtScrollBoundary ? 0 : sample.velocityY,
      moving: sample.moving,
      done: sample.done,
    );
  }

  void _handleTapFeedbackStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _tapFeedbackIndex == null) {
      return;
    }
    if (mounted) setState(() => _tapFeedbackIndex = null);
  }

  void _clearTapFeedback({bool notify = true}) {
    _tapFeedbackClearTimer?.cancel();
    _tapFeedbackClearTimer = null;
    _tapFeedbackController.stop(canceled: true);
    if (notify && mounted) {
      if (_tapFeedbackIndex != null) {
        setState(() => _tapFeedbackIndex = null);
      }
    } else {
      _tapFeedbackIndex = null;
    }
  }

  void _clearTapFeedbackState({bool notify = true}) {
    _clearTapFeedback(notify: notify);
    _tapFeedbackDedupeTimer?.cancel();
    _tapFeedbackDedupeTimer = null;
    _tapFeedbackDedupeIndex = null;
    for (final timer in _pointerFeedbackSuppressions.values) {
      timer.cancel();
    }
    _pointerFeedbackSuppressions.clear();
    _pointerTracker.clear();
  }

  void _handlePointerTap(int index) {
    if (!widget.enableLineTapFeedback ||
        !widget.isActive ||
        widget.isLocked ||
        !mounted) {
      return;
    }
    final duplicate =
        _tapFeedbackDedupeIndex == index && _tapFeedbackDedupeTimer != null;
    if (!duplicate) _showTapFeedback(index);
    _tapFeedbackDedupeIndex = index;
    _tapFeedbackDedupeTimer?.cancel();
    _tapFeedbackDedupeTimer = Timer(kDoubleTapTimeout, () {
      _tapFeedbackDedupeTimer = null;
      _tapFeedbackDedupeIndex = null;
    });
    _schedulePointerFeedbackSuppression(index);
  }

  void _handlePointerInvalid(int index) {
    if (!widget.enableLineTapFeedback ||
        !widget.isActive ||
        widget.isLocked ||
        !mounted) {
      return;
    }
    _schedulePointerFeedbackSuppression(index);
  }

  void _schedulePointerFeedbackSuppression(int index) {
    _pointerFeedbackSuppressions[index]?.cancel();
    _pointerFeedbackSuppressions[index] = Timer(
      _lyricTapFeedbackFallbackWindow,
      () => _pointerFeedbackSuppressions.remove(index)?.cancel(),
    );
  }

  bool _consumePointerFeedbackSuppression(int index) {
    final timer = _pointerFeedbackSuppressions.remove(index);
    if (timer == null) return false;
    timer.cancel();
    return true;
  }

  void _showTapFeedback(int index) {
    if (!widget.enableLineTapFeedback || !mounted) return;
    _tapFeedbackClearTimer?.cancel();
    _tapFeedbackClearTimer = null;
    setState(() => _tapFeedbackIndex = index);
    if (MediaQuery.disableAnimationsOf(context)) {
      _tapFeedbackController.stop(canceled: true);
      _tapFeedbackClearTimer = Timer(_lyricTapFeedbackStaticDuration, () {
        _tapFeedbackClearTimer = null;
        if (mounted) setState(() => _tapFeedbackIndex = null);
      });
      return;
    }
    _tapFeedbackController.forward(from: 0.001);
  }

  GlobalKey _getKeyForIndex(int index) {
    return _itemKeys.putIfAbsent(index, GlobalKey.new);
  }

  GlobalKey _getTextKeyForIndex(int index) {
    return _textKeys.putIfAbsent(index, GlobalKey.new);
  }

  int _indexForPosition(Duration position, List<LyricLine> lyrics) {
    var low = 0;
    var high = lyrics.length - 1;
    var result = -1;
    while (low <= high) {
      final middle = low + ((high - low) >> 1);
      if (lyrics[middle].startTime <= position) {
        result = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return result;
  }

  _LyricLayoutIndex _ensureLayoutIndex({
    required List<LyricLine> lyrics,
    required String query,
    required TextStyle activeStyle,
    required TextStyle inactiveStyle,
    required ColorScheme colors,
    required double textWidth,
    required TextScaler textScaler,
    required TextDirection textDirection,
    required Locale? locale,
  }) {
    final fingerprint = Object.hash(
      identityHashCode(lyrics),
      lyrics.length,
      query,
      activeStyle,
      inactiveStyle,
      colors.primary,
      colors.onPrimary,
      textWidth,
      textScaler,
      textDirection,
      locale,
    );
    if (_layoutIndex == null || _layoutFingerprint != fingerprint) {
      _layoutFingerprint = fingerprint;
      _layoutIndex = _LyricLayoutIndex(
        lyrics: lyrics,
        query: query,
        activeStyle: activeStyle,
        inactiveStyle: inactiveStyle,
        colors: colors,
        textWidth: textWidth,
        textScaler: textScaler,
        textDirection: textDirection,
        locale: locale,
      );
    }
    return _layoutIndex!;
  }

  double? _layoutTargetForLine(
    int index,
    double visibleBottomInset, {
    double lineFraction = 0.5,
    bool clampToBounds = true,
  }) {
    final layoutIndex = _layoutIndex;
    if (layoutIndex == null ||
        index < 0 ||
        index >= layoutIndex.lyrics.length ||
        !_scrollController.hasClients) {
      return null;
    }
    final layout = layoutIndex.layoutFor(
      index,
      active: index == _layoutCurrentIndex,
      selectedMatch: _layoutSelectedMatch?.lineIndex == index
          ? _layoutSelectedMatch
          : null,
    );
    final center =
        _effectiveTopPadding +
        layoutIndex.offsetBefore(
          index,
          currentIndex: _layoutCurrentIndex,
          selectedMatch: _layoutSelectedMatch,
        ) +
        layout.extent * lineFraction;
    final target = center - _playbackAnchorY(visibleBottomInset);
    return clampToBounds
        ? target
              .clamp(
                _scrollController.position.minScrollExtent,
                _scrollController.position.maxScrollExtent,
              )
              .toDouble()
        : target;
  }

  double? _layoutTargetForMatch(
    LyricSearchMatch match,
    double visibleBottomInset,
  ) {
    final layoutIndex = _layoutIndex;
    if (layoutIndex == null ||
        match.lineIndex < 0 ||
        match.lineIndex >= layoutIndex.lyrics.length ||
        !_scrollController.hasClients) {
      return null;
    }
    final lineLayout = layoutIndex.layoutFor(
      match.lineIndex,
      active: match.lineIndex == _layoutCurrentIndex,
      selectedMatch: match,
    );
    final matchCenter =
        _effectiveTopPadding +
        layoutIndex.offsetBefore(
          match.lineIndex,
          currentIndex: _layoutCurrentIndex,
          selectedMatch: match,
        ) +
        lineLayout.matchCenterY;
    return (matchCenter - _playbackAnchorY(visibleBottomInset)).clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
  }

  void _scrollToLyric(
    int index, {
    bool animate = true,
    bool force = false,
    bool ignoreAutoScroll = false,
    bool preservePendingTap = false,
    bool preserveEmphasis = false,
    double? visibleBottomInset,
    Duration? animationDuration,
    double lineFraction = 0.5,
  }) {
    if ((!_autoScroll || widget.suspendAutoScroll) && !ignoreAutoScroll) return;
    if (!_scrollController.hasClients || index < 0) return;
    if (!preservePendingTap) {
      _pendingTappedIndex = null;
      _pendingTapOriginIndex = null;
      _pendingTapAcknowledged = false;
    }
    final waitForMotionReset = _hasLyricMotion;
    _clearLyricMotion(preserveEmphasis: preserveEmphasis);
    final duration = MediaQuery.disableAnimationsOf(context) || !animate
        ? Duration.zero
        : animationDuration ?? const Duration(milliseconds: 460);
    final request = ++_scrollRequestGeneration;
    unawaited(
      _performLyricScroll(
        index: index,
        duration: duration,
        force: force,
        request: request,
        visibleBottomInset: visibleBottomInset ?? widget.visibleBottomInset,
        lineFraction: lineFraction,
        waitForMotionReset: waitForMotionReset,
      ),
    );
  }

  Future<void> _performLyricScroll({
    required int index,
    required Duration duration,
    required bool force,
    required int request,
    required double visibleBottomInset,
    required double lineFraction,
    required bool waitForMotionReset,
  }) async {
    if (!mounted ||
        request != _scrollRequestGeneration ||
        !_scrollController.hasClients) {
      return;
    }
    if (waitForMotionReset) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted ||
          request != _scrollRequestGeneration ||
          !_scrollController.hasClients) {
        return;
      }
    }
    final itemContext = _getKeyForIndex(index).currentContext;
    final renderObject = itemContext?.findRenderObject();
    if (renderObject is RenderBox) {
      await _positionAtPlaybackAnchor(
        renderObject,
        duration,
        visibleBottomInset,
        lineFraction: lineFraction,
      );
      return;
    }
    if (!force) return;

    final target = _layoutTargetForLine(
      index,
      visibleBottomInset,
      lineFraction: lineFraction,
      clampToBounds: duration != Duration.zero,
    );
    if (target == null) return;
    if (duration == Duration.zero) {
      _scrollController.jumpTo(target);
    } else {
      try {
        await _scrollController.animateTo(
          target,
          duration: duration,
          curve: Curves.easeOutCubic,
        );
      } catch (_) {
        // A page/fullscreen transition can detach this list mid-animation.
        return;
      }
    }
    if (!mounted || request != _scrollRequestGeneration) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        request != _scrollRequestGeneration ||
        !_scrollController.hasClients) {
      return;
    }
    final correctedRenderObject = _getKeyForIndex(
      index,
    ).currentContext?.findRenderObject();
    if (correctedRenderObject is RenderBox) {
      await _positionAtPlaybackAnchor(
        correctedRenderObject,
        duration == Duration.zero
            ? Duration.zero
            : const Duration(milliseconds: 120),
        visibleBottomInset,
        lineFraction: lineFraction,
        clampToBounds: duration != Duration.zero,
      );
    }
  }

  void _scrollToMatch(
    LyricSearchMatch match, {
    required bool animate,
    required double Function() visibleBottomInset,
  }) {
    if (!_scrollController.hasClients || match.lineIndex < 0) return;
    _pendingTappedIndex = null;
    _pendingTapOriginIndex = null;
    _pendingTapAcknowledged = false;
    final waitForMotionReset = _hasLyricMotion;
    _clearLyricMotion();
    final request = ++_scrollRequestGeneration;
    unawaited(
      _performMatchScroll(
        match: match,
        animate: animate,
        request: request,
        visibleBottomInset: visibleBottomInset,
        waitForMotionReset: waitForMotionReset,
      ),
    );
  }

  void _centerCurrentIfOutside({
    required bool animate,
    required double visibleBottomInset,
  }) {
    final index = _currentLyricIndex;
    if (!mounted ||
        index == null ||
        index < 0 ||
        !_scrollController.hasClients) {
      return;
    }
    final viewport = _viewportKey.currentContext?.findRenderObject();
    final item = _getKeyForIndex(index).currentContext?.findRenderObject();
    if (viewport is RenderBox &&
        item is RenderBox &&
        viewport.attached &&
        item.attached) {
      final top = item.localToGlobal(Offset.zero, ancestor: viewport).dy;
      final bottom = top + item.size.height;
      final visibleHeight = _visibleViewportHeight(visibleBottomInset);
      if (bottom >= 0 && top <= visibleHeight) return;
    }
    _scrollToLyric(
      index,
      animate: animate,
      force: true,
      ignoreAutoScroll: true,
      visibleBottomInset: visibleBottomInset,
      animationDuration: const Duration(milliseconds: 280),
    );
  }

  Future<void> _performMatchScroll({
    required LyricSearchMatch match,
    required bool animate,
    required int request,
    required double Function() visibleBottomInset,
    required bool waitForMotionReset,
  }) async {
    if (!mounted ||
        request != _scrollRequestGeneration ||
        !_scrollController.hasClients) {
      return;
    }
    if (waitForMotionReset) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted ||
          request != _scrollRequestGeneration ||
          !_scrollController.hasClients) {
        return;
      }
    }
    var inset = visibleBottomInset();
    var target = _layoutTargetForMatch(match, inset);
    if (target == null) return;
    final reducedMotion = MediaQuery.disableAnimationsOf(context) || !animate;
    final visibleHeight = _visibleViewportHeight(inset);
    final far =
        (target - _scrollController.position.pixels).abs() >
        visibleHeight * 1.5;

    if (reducedMotion || far) {
      _scrollController.jumpTo(target);
    } else {
      if (!await _animateToTarget(
        target,
        duration: const Duration(milliseconds: 280),
        request: request,
      )) {
        return;
      }
    }

    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        request != _scrollRequestGeneration ||
        !_scrollController.hasClients) {
      return;
    }
    inset = visibleBottomInset();
    target =
        _preciseTargetForMatch(match, inset) ??
        _layoutTargetForMatch(match, inset);
    if (target == null ||
        (target - _scrollController.position.pixels).abs() < 0.5) {
      return;
    }
    if (reducedMotion) {
      _scrollController.jumpTo(target);
      return;
    }
    await _animateToTarget(
      target,
      duration: far
          ? const Duration(milliseconds: 160)
          : const Duration(milliseconds: 120),
      request: request,
    );
  }

  Future<bool> _animateToTarget(
    double target, {
    required Duration duration,
    required int request,
  }) async {
    if (!mounted ||
        request != _scrollRequestGeneration ||
        !_scrollController.hasClients) {
      return false;
    }
    try {
      await _scrollController.animateTo(
        target,
        duration: duration,
        curve: Curves.easeOutCubic,
      );
    } catch (_) {
      return false;
    }
    return mounted &&
        request == _scrollRequestGeneration &&
        _scrollController.hasClients;
  }

  double? _preciseTargetForMatch(
    LyricSearchMatch match,
    double visibleBottomInset,
  ) {
    if (!_scrollController.hasClients) return null;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    final paragraph = _getTextKeyForIndex(
      match.lineIndex,
    ).currentContext?.findRenderObject();
    if (viewport is! RenderBox ||
        paragraph is! RenderParagraph ||
        !viewport.attached ||
        !paragraph.attached ||
        match.start < 0 ||
        match.end <= match.start ||
        match.end > paragraph.text.toPlainText().length) {
      return null;
    }
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: match.start, extentOffset: match.end),
    );
    if (boxes.isEmpty) return null;
    var top = boxes.first.top;
    var bottom = boxes.first.bottom;
    var left = boxes.first.left;
    var right = boxes.first.right;
    for (final box in boxes.skip(1)) {
      top = math.min(top, box.top);
      bottom = math.max(bottom, box.bottom);
      left = math.min(left, box.left);
      right = math.max(right, box.right);
    }
    final matchCenter = paragraph.localToGlobal(
      Offset((left + right) / 2, (top + bottom) / 2),
      ancestor: viewport,
    );
    return (_scrollController.position.pixels +
            matchCenter.dy -
            _playbackAnchorY(visibleBottomInset))
        .clamp(
          _scrollController.position.minScrollExtent,
          _scrollController.position.maxScrollExtent,
        );
  }

  double _visibleViewportHeight(double visibleBottomInset) {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    final fullHeight = viewport is RenderBox
        ? viewport.size.height
        : _scrollController.position.viewportDimension;
    if (fullHeight <= 1) return 1;
    return (fullHeight - visibleBottomInset.clamp(0.0, fullHeight - 1))
        .clamp(1.0, fullHeight)
        .toDouble();
  }

  double _playbackAnchorY(double visibleBottomInset) {
    return _visibleViewportHeight(visibleBottomInset) *
        widget.playbackAnchorFraction;
  }

  _LyricBrowseAnchor? _captureBrowseAnchor() {
    final layoutIndex = _layoutIndex;
    if (layoutIndex == null || !_scrollController.hasClients) return null;
    final anchorY = _playbackAnchorY(widget.visibleBottomInset);
    final lineIndex = _lineAtPlaybackAnchor(layoutIndex.lyrics, anchorY);
    if (lineIndex == null) return null;
    final lineOffset = layoutIndex.offsetBefore(
      lineIndex,
      currentIndex: _layoutCurrentIndex,
      selectedMatch: _layoutSelectedMatch,
    );
    final extent = layoutIndex.extentFor(
      lineIndex,
      currentIndex: _layoutCurrentIndex,
      selectedMatch: _layoutSelectedMatch,
    );
    final fraction =
        ((_scrollController.position.pixels +
                    anchorY -
                    _effectiveTopPadding -
                    lineOffset) /
                extent)
            .clamp(0.0, 1.0)
            .toDouble();
    return (
      lyrics: layoutIndex.lyrics,
      lineIndex: lineIndex,
      fraction: fraction,
    );
  }

  int? _lineAtPlaybackAnchor(List<LyricLine> lyrics, double anchorY) {
    if (lyrics.isEmpty) return null;
    final layoutIndex = _layoutIndex;
    if (layoutIndex == null || !_scrollController.hasClients) {
      final selectedMatch = widget.selectedSearchMatch;
      if (selectedMatch != null &&
          selectedMatch.lineIndex >= 0 &&
          selectedMatch.lineIndex < lyrics.length) {
        return selectedMatch.lineIndex;
      }
      final currentIndex = _currentLyricIndex;
      return currentIndex != null &&
              currentIndex >= 0 &&
              currentIndex < lyrics.length
          ? currentIndex
          : 0;
    }

    final anchorOffset =
        _scrollController.position.pixels + anchorY - _effectiveTopPadding;
    var lineOffset = 0.0;
    for (var index = 0; index < lyrics.length; index++) {
      final extent = layoutIndex.extentFor(
        index,
        currentIndex: _layoutCurrentIndex,
        selectedMatch: _layoutSelectedMatch,
      );
      if (anchorOffset <= lineOffset + extent) return index;
      lineOffset += extent;
    }
    return lyrics.length - 1;
  }

  Widget _buildPlaybackLineControls({
    required List<LyricLine> lyrics,
    required double textWidth,
    required double sideColumnWidth,
    required double maxWidth,
    required double maxHeight,
    required double visibleHeight,
  }) {
    final trackKey = ref.watch(
      lyricControllerProvider.select(
        (state) => state.isLoading ? null : state.trackKey,
      ),
    );
    return AnimatedBuilder(
      animation: _scrollController,
      builder: (context, _) {
        final index = _lineAtPlaybackAnchor(
          lyrics,
          visibleHeight * widget.playbackAnchorFraction,
        );
        if (index == null || lyrics[index].startTime.isNegative) {
          return const SizedBox.shrink();
        }

        final line = lyrics[index];
        final anchorY = visibleHeight * widget.playbackAnchorFraction;
        const rowHeight = 48.0;
        final top = (anchorY - rowHeight / 2)
            .clamp(0.0, math.max(0.0, maxHeight - rowHeight))
            .toDouble();
        final rowWidth = textWidth + sideColumnWidth * 2;
        final time = formatDuration(line.startTime, padHours: false);

        return Positioned(
          key: const ValueKey('playback-line-controls'),
          left: (maxWidth - rowWidth) / 2,
          top: top,
          width: rowWidth,
          height: rowHeight,
          child: Row(
            children: [
              SizedBox(
                width: sideColumnWidth,
                child: Center(
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: IconTheme.merge(
                      data: const IconThemeData(size: 18),
                      child: PlayerSliceCutButton(
                        position: line.startTime,
                        trackKey: trackKey,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(width: textWidth),
              SizedBox(
                key: const ValueKey('playback-line-time-column'),
                width: sideColumnWidth,
                child: Center(
                  child: IgnorePointer(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          key: const ValueKey('playback-line-time'),
                          time,
                          maxLines: 1,
                          softWrap: false,
                          textAlign: TextAlign.center,
                          style:
                              (Theme.of(context).textTheme.labelMedium ??
                                      const TextStyle())
                                  .copyWith(
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _positionAtPlaybackAnchor(
    RenderBox item,
    Duration duration,
    double visibleBottomInset, {
    double lineFraction = 0.5,
    bool clampToBounds = true,
  }) async {
    if (!_scrollController.hasClients) return;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !item.attached || !viewport.attached) return;
    final itemAnchor = item.localToGlobal(
      Offset(item.size.width / 2, item.size.height * lineFraction),
      ancestor: viewport,
    );
    final targetOffset =
        _scrollController.position.pixels +
        itemAnchor.dy -
        _playbackAnchorY(visibleBottomInset);
    final target = clampToBounds
        ? targetOffset
              .clamp(
                _scrollController.position.minScrollExtent,
                _scrollController.position.maxScrollExtent,
              )
              .toDouble()
        : targetOffset;
    if ((target - _scrollController.position.pixels).abs() < 0.5) return;
    try {
      if (duration == Duration.zero) {
        _scrollController.jumpTo(target);
      } else {
        await _scrollController.animateTo(
          target,
          duration: duration,
          curve: Curves.easeOutCubic,
        );
      }
    } catch (_) {
      // Entering/exiting fullscreen can remove the list while it is moving.
    }
  }

  void _onLyricTap(int index, List<LyricLine> lyrics) {
    if (index < 0 || index >= lyrics.length) return;
    final target = lyrics[index].startTime;
    final playbackIndex = ref.read(currentLyricIndexProvider);
    final originIndex = playbackIndex >= 0 ? playbackIndex : _currentLyricIndex;
    final emphasisOrigin = _currentLyricIndex ?? originIndex ?? -1;
    final centers = _captureLyricCenters();
    final textCenters = _captureLyricTextCenters();
    _resumeAutoScrollTimer?.cancel();
    _resumeAutoScrollTimer = null;
    _userScrollInProgress = false;
    final request = ++_scrollRequestGeneration;
    _pendingLyricEmphasisFromIndex =
        _reducedMotion || MediaQuery.disableAnimationsOf(context)
        ? null
        : emphasisOrigin;
    setState(() {
      _autoScroll = true;
      _pendingDiscontinuity = null;
      _pendingTappedIndex = index;
      _pendingTapOriginIndex = originIndex;
      _pendingTapAcknowledged = false;
      _currentLyricIndex = index;
    });
    _pendingLyricY
      ..clear()
      ..addAll(centers);
    _pendingLyricTextY
      ..clear()
      ..addAll(textCenters);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _scrollRequestGeneration) return;
      if (widget.suspendAutoScroll ||
          widget.searchMode ||
          widget.selectedSearchMatch != null) {
        if (!_reducedMotion && !MediaQuery.disableAnimationsOf(context)) {
          _springPreset = ref.read(playerLyricSettingsProvider).springPreset;
          _startLyricEmphasisTransition(
            targetIndex: index,
            previousIndex: emphasisOrigin,
            indices: _itemKeys.keys,
            spring: _lyricPositionSpring(_springPreset),
            startAt: _lyricMotionSeconds,
          );
        }
        _scrollToLyric(
          index,
          force: true,
          ignoreAutoScroll: true,
          preservePendingTap: true,
          preserveEmphasis: true,
        );
      } else {
        _startLyricScrollSpring(
          index,
          stagger: false,
          previousIndex: originIndex,
          previousEmphasisIndex: emphasisOrigin,
          request: request,
        );
      }
    });
    if (widget.onSeekRequested case final callback?) {
      callback(target);
    } else {
      ref.read(audioPlayerControllerProvider.notifier).seekAndPersist(target);
    }
  }

  void _beginUserBrowse() {
    _resumeAutoScrollTimer?.cancel();
    _resumeAutoScrollTimer = null;
    _userScrollInProgress = true;
    final wasFollowing = _autoScroll;
    _autoScroll = false;
    _scrollRequestGeneration++;
    _pendingDiscontinuity = null;
    _pendingTappedIndex = null;
    _pendingTapOriginIndex = null;
    _pendingTapAcknowledged = false;
    _freezeLyricMotion();
    if (wasFollowing) _lyricMotionFrame.value++;
  }

  void _endUserBrowse() {
    if (!_userScrollInProgress) return;
    _userScrollInProgress = false;
    _scheduleAutoScrollResume();
  }

  void _endLyricScrollHold(int pointer) {
    if (_lyricScrollHoldPointer != pointer) return;
    _lyricScrollHoldPointer = null;
    if (!_scrollController.hasClients ||
        !_scrollController.position.isScrollingNotifier.value) {
      _endUserBrowse();
    }
  }

  void _scheduleAutoScrollResume() {
    _resumeAutoScrollTimer?.cancel();
    _resumeAutoScrollTimer = Timer(const Duration(seconds: 3), () {
      _resumeAutoScrollTimer = null;
      if (!mounted) return;
      setState(() => _autoScroll = true);
      final playbackIndex = ref.read(currentLyricIndexProvider);
      final index = playbackIndex >= 0
          ? playbackIndex
          : _currentLyricIndex ??
                (_layoutIndex?.lyrics.isNotEmpty == true ? 0 : null);
      if (index == null ||
          index < 0 ||
          !widget.isActive ||
          !_tickerModeEnabled ||
          !_appLifecycleVisible ||
          widget.suspendAutoScroll ||
          widget.isLocked) {
        return;
      }
      if (_shouldAnimateLyrics) {
        _startLyricScrollSpring(
          index,
          stagger: false,
          previousIndex: _currentLyricIndex,
        );
      } else {
        _scrollToLyric(
          index,
          animate: false,
          force: true,
          ignoreAutoScroll: true,
        );
      }
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if ((notification is ScrollUpdateNotification &&
            notification.dragDetails != null) ||
        (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle)) {
      _beginUserBrowse();
    } else if (notification is ScrollEndNotification && _userScrollInProgress) {
      _endUserBrowse();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(isPlayingProvider);
    ref.listen<bool>(isPlayingProvider, (previous, playing) {
      if (previous == true && !playing) {
        if (_scrollSpringTargetIndex != null) return;
        _scrollRequestGeneration++;
        _clearLyricMotion(preserveEmphasis: true);
      }
    });
    ref.listen<AsyncValue<PositionDiscontinuity>>(
      positionDiscontinuityProvider,
      (previous, next) {
        final discontinuity = next.asData?.value;
        if (discontinuity == null) return;
        final lyricContent = ref.read(lyricControllerProvider);
        final seekingPosition =
            widget.seekingPositionListenable?.value?.position ??
            widget.seekingPosition;
        _handlePositionDiscontinuity(
          discontinuity,
          lyrics: lyricContent.displayLyrics,
          trackKey: lyricContent.trackKey,
          seekingPosition: seekingPosition,
        );
      },
    );
    final seekingPositionListenable = widget.seekingPositionListenable;
    if (seekingPositionListenable != null) {
      return ValueListenableBuilder<PlayerSeekPreview?>(
        valueListenable: seekingPositionListenable,
        builder: (context, seekPreview, _) =>
            _buildDisplay(context, seekPreview?.position),
      );
    }
    return _buildDisplay(context, widget.seekingPosition);
  }

  Widget _buildDisplay(BuildContext context, Duration? seekingPosition) {
    final previewChanged = seekingPosition != _lastSeekingPosition;
    _lastSeekingPosition = seekingPosition;
    if (previewChanged) {
      _lyricEmphasisMotion.clear();
      _pendingLyricEmphasisFromIndex = null;
    }
    final lyricContent = ref.watch(
      lyricControllerProvider.select(
        (state) => (lyrics: state.displayLyrics, trackKey: state.trackKey),
      ),
    );
    final lyrics = lyricContent.lyrics;
    final playbackIndex = ref.watch(currentLyricIndexProvider);
    final settings = ref.watch(playerLyricSettingsProvider);
    final springPreset = ref.watch(
      playerLyricSettingsProvider.select((state) => state.springPreset),
    );
    final isPlaying = ref.watch(isPlayingProvider);
    if (_springPreset != springPreset) {
      _springPreset = springPreset;
      _retargetLyricMotion(springPreset);
    }
    if (lyrics.isEmpty) {
      _clearTapFeedbackState(notify: false);
      _clearLyricMotion(notify: false);
      _lastDisplayLyrics = null;
      _lastTrackKey = lyricContent.trackKey;
      _currentLyricIndex = null;
      _pendingDiscontinuity = null;
      _pendingTappedIndex = null;
      _pendingTapOriginIndex = null;
      _pendingTapAcknowledged = false;
      _layoutFingerprint = null;
      _layoutIndex = null;
      return Center(child: Text(S.of(context).noSubtitlesAvailable));
    }
    final lyricsChanged =
        !identical(_lastDisplayLyrics, lyrics) ||
        _lastTrackKey != lyricContent.trackKey;
    if (lyricsChanged) {
      _resumeAutoScrollTimer?.cancel();
      _resumeAutoScrollTimer = null;
      _autoScroll = true;
      _userScrollInProgress = false;
      _lastDisplayLyrics = lyrics;
      _lastTrackKey = lyricContent.trackKey;
      _scrollRequestGeneration++;
      _clearLyricMotion(notify: false);
      _clearTapFeedbackState(notify: false);
      _currentLyricIndex = null;
      _pendingDiscontinuity = null;
      _pendingTappedIndex = null;
      _pendingTapOriginIndex = null;
      _pendingTapAcknowledged = false;
      _itemKeys.clear();
      _textKeys.clear();
      _layoutFingerprint = null;
      _layoutIndex = null;
    }
    final seekingIndex = seekingPosition == null
        ? null
        : _indexForPosition(seekingPosition, lyrics);
    final pendingDiscontinuity = _pendingDiscontinuity;
    // Playback can pass a short seek target before this widget builds.
    final discontinuityAcknowledged =
        pendingDiscontinuity != null &&
        (playbackIndex == pendingDiscontinuity.index ||
            (playbackIndex >= 0 &&
                playbackIndex != pendingDiscontinuity.originIndex));
    if (discontinuityAcknowledged) _pendingDiscontinuity = null;
    if (_pendingTappedIndex != null) {
      final originIndex = _pendingTapOriginIndex;
      final requestSettled =
          seekingPosition != null ||
          (playbackIndex >= 0 && playbackIndex != originIndex);
      if (requestSettled) {
        _pendingTappedIndex = null;
        _pendingTapOriginIndex = null;
        _pendingTapAcknowledged = false;
      }
    }
    final pendingIndex = seekingPosition == null ? _pendingTappedIndex : null;
    final currentIndex =
        seekingIndex ??
        (discontinuityAcknowledged ? null : pendingDiscontinuity?.index) ??
        pendingIndex ??
        playbackIndex;

    if ((currentIndex != _currentLyricIndex || previewChanged) &&
        currentIndex >= 0) {
      final previous = _currentLyricIndex;
      final previousCenters = _captureLyricCenters();
      final previousTextCenters = _captureLyricTextCenters();
      final isDiscontinuity = pendingDiscontinuity != null;
      final continueScrollSpring =
          _scrollSpringTargetIndex != null &&
          !isDiscontinuity &&
          !previewChanged;
      final animateEmphasis =
          previous != null &&
          !isDiscontinuity &&
          !previewChanged &&
          widget.isActive &&
          _tickerModeEnabled &&
          _appLifecycleVisible &&
          !MediaQuery.disableAnimationsOf(context);
      _pendingLyricEmphasisFromIndex = animateEmphasis ? previous : null;
      _currentLyricIndex = currentIndex;
      final restoredFirstLayout = previous == null && _hasStoredScrollOffset;
      final restoreFollowing =
          restoredFirstLayout &&
          _restoreFollowing &&
          widget.snapToCurrentOnFirstLayout;
      if (restoredFirstLayout) {
        _hasStoredScrollOffset = false;
        _restoreFollowing = false;
      }
      if (!restoredFirstLayout || restoreFollowing) {
        final motionRequest = ++_scrollRequestGeneration;
        final canSpring =
            previous != null &&
            !isDiscontinuity &&
            !previewChanged &&
            currentIndex > previous &&
            isPlaying &&
            seekingPosition == null &&
            widget.isActive &&
            !widget.suspendAutoScroll &&
            !widget.searchMode &&
            widget.selectedSearchMatch == null &&
            _autoScroll &&
            _tickerModeEnabled &&
            _appLifecycleVisible &&
            !MediaQuery.disableAnimationsOf(context);
        if (canSpring || continueScrollSpring) {
          _pendingLyricY
            ..clear()
            ..addAll(previousCenters);
          _pendingLyricTextY
            ..clear()
            ..addAll(previousTextCenters);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              motionRequest != _scrollRequestGeneration ||
              !widget.isActive ||
              !_tickerModeEnabled ||
              !_appLifecycleVisible) {
            return;
          }
          if (continueScrollSpring) {
            _startLyricScrollSpring(
              currentIndex,
              stagger: false,
              previousIndex: previous,
              previousEmphasisIndex: previous,
              request: motionRequest,
            );
            return;
          }
          if (_pendingTappedIndex == currentIndex && !isDiscontinuity) return;
          if (canSpring) {
            _startLyricSpringFollow(
              index: currentIndex,
              previousIndex: previous,
              request: motionRequest,
            );
          } else {
            if (_pendingLyricEmphasisFromIndex case final previousIndex?) {
              _startLyricEmphasisTransition(
                targetIndex: currentIndex,
                previousIndex: previousIndex,
                indices: _itemKeys.keys,
                spring: _lyricPositionSpring(_springPreset),
                startAt: _lyricMotionSeconds,
              );
            }
            _scrollToLyric(
              currentIndex,
              preserveEmphasis: animateEmphasis,
              animate:
                  !isDiscontinuity &&
                  !previewChanged &&
                  widget.isActive &&
                  seekingPosition == null &&
                  !restoreFollowing &&
                  !(widget.snapToCurrentOnFirstLayout && previous == null),
              force:
                  isDiscontinuity ||
                  previewChanged ||
                  previous == null ||
                  (currentIndex - previous).abs() > 5,
            );
          }
        });
      }
    }

    return GestureDetector(
      onLongPress: widget.onLongPress,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final layoutWidth = constraints.maxWidth;
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
          final baseStyle = theme.textTheme.bodyLarge ?? const TextStyle();
          final weight = _fontWeight(settings.fullFontWeight);
          final textScaler = MediaQuery.textScalerOf(context);
          final textDirection = Directionality.of(context);
          final locale = Localizations.maybeLocaleOf(context);
          var timeColumnWidth = 48.0;
          if (widget.showPlaybackLineControls && lyrics.isNotEmpty) {
            final timePainter = TextPainter(
              text: TextSpan(
                text: formatDuration(lyrics.last.startTime, padHours: false),
                style: (theme.textTheme.labelMedium ?? const TextStyle())
                    .copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
              textDirection: textDirection,
              textScaler: textScaler,
              locale: locale,
            )..layout();
            timeColumnWidth = math.max(48.0, timePainter.width + 2);
            timePainter.dispose();
          }
          final minLyricWidth = math.min(64.0, math.max(1.0, layoutWidth - 96));
          final sideColumnWidth = math.min(
            timeColumnWidth,
            math.max(0.0, (layoutWidth - minLyricWidth) / 2),
          );
          final availableTextWidth = math.max(1.0, layoutWidth - 56);
          final requestedTextWidth = math.min(
            widget.contentWidth ?? availableTextWidth,
            availableTextWidth,
          );
          final maxTextWidth = widget.showPlaybackLineControls
              ? math.max(1.0, layoutWidth - sideColumnWidth * 2)
              : requestedTextWidth;
          final textWidth = widget.showPlaybackLineControls
              ? math.min(requestedTextWidth, maxTextWidth)
              : requestedTextWidth;
          final widthScale = _lyricWidthScale(textWidth);
          final activeStyle = baseStyle.copyWith(
            color: colors.onSurface,
            fontWeight: weight,
            fontSize: settings.fullActiveFontSize * widthScale,
            height: settings.fullLineHeight,
          );
          final inactiveStyle = baseStyle.copyWith(
            color: colors.onSurface.withValues(alpha: 0.34),
            fontWeight: weight,
            fontSize: settings.fullInactiveFontSize * widthScale,
            height: settings.fullLineHeight,
          );
          final normalizedQuery = widget.searchQuery.trim();
          final normalizedLayoutQuery =
              (widget.layoutSearchQuery ?? widget.searchQuery).trim();
          final previousLayout = _layoutIndex;
          final metricsChanged =
              previousLayout != null &&
              (previousLayout.textWidth != textWidth ||
                  previousLayout.activeStyle.copyWith(
                        color: activeStyle.color,
                      ) !=
                      activeStyle ||
                  previousLayout.inactiveStyle.copyWith(
                        color: inactiveStyle.color,
                      ) !=
                      inactiveStyle ||
                  previousLayout.textScaler != textScaler ||
                  previousLayout.textDirection != textDirection ||
                  previousLayout.locale != locale);
          if (metricsChanged && _scrollSpringTargetIndex != null) {
            _pendingLyricY
              ..clear()
              ..addAll(_captureLyricCenters());
            _pendingLyricTextY
              ..clear()
              ..addAll(_captureLyricTextCenters());
          }
          final match = widget.selectedSearchMatch;
          final canRestore =
              metricsChanged &&
              !_userScrollInProgress &&
              _scrollController.hasClients &&
              identical(match, _layoutSelectedMatch);
          final matchTarget = canRestore && match != null
              ? _preciseTargetForMatch(match, widget.visibleBottomInset) ??
                    _layoutTargetForMatch(match, widget.visibleBottomInset)
              : null;
          final restoreMatch =
              matchTarget != null &&
              ((matchTarget - _scrollController.position.pixels).abs() <= 2.1 ||
                  _scrollController.position.isScrollingNotifier.value);
          final storedBrowseAnchor = _restoredBrowseAnchor;
          _restoredBrowseAnchor = null;
          final restoreBrowseAnchor =
              storedBrowseAnchor != null &&
                  identical(storedBrowseAnchor.lyrics, lyrics)
              ? storedBrowseAnchor
              : null;
          if (restoreBrowseAnchor != null) {
            _autoScroll = false;
            _scheduleAutoScrollResume();
          }
          final browsedAnchor =
              restoreBrowseAnchor ??
              (canRestore &&
                      !restoreMatch &&
                      (!_autoScroll || widget.suspendAutoScroll)
                  ? _captureBrowseAnchor()
                  : null);
          final request = _scrollRequestGeneration;
          final layoutIndex = _ensureLayoutIndex(
            lyrics: lyrics,
            query: normalizedLayoutQuery,
            activeStyle: activeStyle,
            inactiveStyle: inactiveStyle,
            colors: colors,
            textWidth: textWidth,
            textScaler: textScaler,
            textDirection: textDirection,
            locale: locale,
          );
          _layoutCurrentIndex = currentIndex;
          _layoutSelectedMatch = widget.selectedSearchMatch;
          if (previousLayout != null &&
              previousLayout.activeTextScale != layoutIndex.activeTextScale &&
              _lyricEmphasisMotion.isNotEmpty) {
            _retargetLyricEmphasisMotion(_lyricPositionSpring(_springPreset));
          }
          if (canRestore || browsedAnchor != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted ||
                  _userScrollInProgress ||
                  request != _scrollRequestGeneration ||
                  !identical(layoutIndex, _layoutIndex) ||
                  !identical(match, widget.selectedSearchMatch)) {
                return;
              }
              if (restoreMatch && match != null) {
                _scrollToMatch(
                  match,
                  animate: false,
                  visibleBottomInset: () => widget.visibleBottomInset,
                );
              } else if (browsedAnchor != null) {
                _scrollToLyric(
                  browsedAnchor.lineIndex,
                  animate: false,
                  force: true,
                  ignoreAutoScroll: true,
                  preserveEmphasis: _lyricEmphasisMotion.isNotEmpty,
                  lineFraction: browsedAnchor.fraction,
                );
              } else if (_scrollSpringTargetIndex != null &&
                  _autoScroll &&
                  !widget.suspendAutoScroll) {
                _startLyricScrollSpring(
                  currentIndex,
                  stagger: false,
                  previousIndex: _scrollSpringOriginIndex,
                  request: request,
                );
              } else if (_autoScroll && !widget.suspendAutoScroll) {
                _scrollToLyric(
                  currentIndex,
                  animate: false,
                  force: true,
                  preserveEmphasis: _lyricEmphasisMotion.isNotEmpty,
                );
              }
            });
          }
          final firstMatch = widget.selectedSearchMatch?.lineIndex == 0
              ? widget.selectedSearchMatch
              : null;
          final lastIndex = lyrics.length - 1;
          final lastMatch = widget.selectedSearchMatch?.lineIndex == lastIndex
              ? widget.selectedSearchMatch
              : null;
          final firstLayout = layoutIndex.layoutFor(
            0,
            active: currentIndex == 0,
            selectedMatch: firstMatch,
          );
          final lastLayout = layoutIndex.layoutFor(
            lastIndex,
            active: currentIndex == lastIndex,
            selectedMatch: lastMatch,
          );
          final visibleHeight =
              (constraints.maxHeight -
                      widget.visibleBottomInset.clamp(
                        0.0,
                        math.max(0.0, constraints.maxHeight - 1),
                      ))
                  .clamp(1.0, constraints.maxHeight)
                  .toDouble();
          final anchorY = visibleHeight * widget.playbackAnchorFraction;
          final firstAnchor = firstMatch == null
              ? firstLayout.extent / 2
              : firstLayout.matchCenterY;
          final lastAnchor = lastMatch == null
              ? lastLayout.extent / 2
              : lastLayout.matchCenterY;
          final effectiveTopPadding = math.max(0.0, anchorY - firstAnchor);
          final effectiveBottomPadding = math.max(
            0.0,
            constraints.maxHeight - anchorY - (lastLayout.extent - lastAnchor),
          );
          _effectiveTopPadding = effectiveTopPadding;
          final rowWidth = math.min(
            math.max(1.0, constraints.maxWidth),
            textWidth * math.max(1.0, layoutIndex.activeTextScale) + 32,
          );

          Widget buildLyricRow(int index, {bool positionedOverlay = false}) {
            final lyric = lyrics[index];
            final active = index == currentIndex;
            final style = inactiveStyle.copyWith(color: colors.onSurface);
            final lyricRow = Listener(
              behavior:
                  widget.enableLineTapFeedback &&
                      widget.isActive &&
                      !widget.isLocked
                  ? HitTestBehavior.opaque
                  : HitTestBehavior.deferToChild,
              onPointerDown: widget.isActive && !widget.isLocked
                  ? (event) {
                      if (_lyricScrollMotion != null) {
                        _lyricScrollHoldPointer = event.pointer;
                        _beginUserBrowse();
                      }
                      if (widget.enableLineTapFeedback) {
                        _pointerTracker.handlePointerDown(event, index);
                      }
                    }
                  : null,
              onPointerMove:
                  widget.enableLineTapFeedback &&
                      widget.isActive &&
                      !widget.isLocked
                  ? _pointerTracker.handlePointerMove
                  : null,
              onPointerUp: (event) {
                _endLyricScrollHold(event.pointer);
                if (widget.enableLineTapFeedback &&
                    widget.isActive &&
                    !widget.isLocked) {
                  _pointerTracker.handlePointerUp(event);
                }
              },
              onPointerCancel: (event) {
                _endLyricScrollHold(event.pointer);
                if (widget.enableLineTapFeedback &&
                    widget.isActive &&
                    !widget.isLocked) {
                  _pointerTracker.handlePointerCancel(event);
                }
              },
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  key: _getKeyForIndex(index),
                  borderRadius: BorderRadius.circular(12),
                  overlayColor: widget.enableLineTapFeedback
                      ? const WidgetStatePropertyAll(Colors.transparent)
                      : null,
                  splashFactory: widget.enableLineTapFeedback
                      ? NoSplash.splashFactory
                      : null,
                  onTap: widget.isLocked
                      ? null
                      : () {
                          if (!_consumePointerFeedbackSuppression(index)) {
                            _showTapFeedback(index);
                          }
                          _onLyricTap(index, lyrics);
                        },
                  onDoubleTap: widget.isLocked || widget.onLineDoubleTap == null
                      ? null
                      : () {
                          if (!_consumePointerFeedbackSuppression(index) &&
                              _tapFeedbackIndex != index) {
                            _showTapFeedback(index);
                          }
                          widget.onLineDoubleTap!.call();
                        },
                  onLongPress: widget.onLongPress == null
                      ? null
                      : () {
                          _pointerTracker.clear();
                          widget.onLongPress!.call();
                        },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 16,
                    ),
                    child: Align(
                      alignment: Alignment.center,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: textWidth),
                        child: AnimatedBuilder(
                          animation: _lyricMotionFrame,
                          builder: (context, _) {
                            final target = _lyricEmphasisTarget(
                              index,
                              currentIndex,
                            );
                            final emphasis = _lyricEmphasisValue(index);
                            final reducedMotion =
                                MediaQuery.disableAnimationsOf(context);
                            final opacity = reducedMotion
                                ? target.opacity
                                : emphasis.opacity;
                            return Transform.scale(
                              scale: reducedMotion
                                  ? (active ? target.scale : 1.0)
                                  : emphasis.scale,
                              filterQuality: _autoScroll
                                  ? FilterQuality.low
                                  : null,
                              transformHitTests: true,
                              child: _HighlightedLyricText(
                                key: _getTextKeyForIndex(index),
                                text: lyric.text,
                                query: normalizedQuery,
                                selectedMatch:
                                    widget.selectedSearchMatch?.lineIndex ==
                                        index
                                    ? widget.selectedSearchMatch
                                    : null,
                                style: style.copyWith(
                                  color: colors.onSurface.withValues(
                                    alpha: opacity,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            final content = widget.enableLineTapFeedback
                ? _buildLyricTapFeedbackSurface(
                    opacity: _tapFeedbackOpacity,
                    active: _tapFeedbackIndex == index,
                    reducedMotion: MediaQuery.disableAnimationsOf(context),
                    color: colors.onSurface,
                    keyValue: 'full-lyric-tap-feedback-$index',
                    child: lyricRow,
                  )
                : lyricRow;
            final motion = _buildLyricMotion(
              index: index,
              translateWithMotion: !positionedOverlay,
              child: IndexedSemantics(
                index: index,
                child: RepaintBoundary(
                  child: Align(
                    alignment: Alignment.center,
                    child: SizedBox(
                      width: rowWidth,
                      height: layoutIndex.extentFor(
                        index,
                        currentIndex: currentIndex,
                        selectedMatch: widget.selectedSearchMatch,
                      ),
                      child: Semantics(
                        selected: active,
                        button: !widget.isLocked,
                        child: content,
                      ),
                    ),
                  ),
                ),
              ),
            );
            if (!positionedOverlay) return motion;
            final extent = layoutIndex.extentFor(
              index,
              currentIndex: currentIndex,
              selectedMatch: widget.selectedSearchMatch,
            );
            final center = _lyricMotionCenter(
              index,
              _lyricContentCenter(index),
            );
            return Positioned(
              left: 0,
              right: 0,
              top: center - extent / 2,
              height: extent,
              child: motion,
            );
          }

          return SizedBox.expand(
            key: _viewportKey,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (widget.showPlaybackLineControls)
                  Positioned(
                    key: const ValueKey('playback-line-indicator'),
                    left: (constraints.maxWidth - textWidth) / 2,
                    top: anchorY - 0.5,
                    width: textWidth,
                    height: 1,
                    child: IgnorePointer(
                      child: ColoredBox(
                        color: colors.onSurface.withValues(alpha: 0.15),
                      ),
                    ),
                  ),
                ValueListenableBuilder<int>(
                  valueListenable: _retainedScrollSpringRowsFrame,
                  builder: (context, _, _) =>
                      NotificationListener<ScrollNotification>(
                        onNotification: _handleScrollNotification,
                        child: _RetainedLyricListView.builder(
                          key: const ValueKey('full-lyric-list'),
                          controller: _scrollController,
                          physics: const AlwaysScrollableScrollPhysics(
                            parent: ClampingScrollPhysics(),
                          ),
                          padding: EdgeInsets.fromLTRB(
                            0,
                            effectiveTopPadding,
                            0,
                            effectiveBottomPadding,
                          ),
                          itemCount: lyrics.length,
                          itemExtentBuilder: (index, dimensions) =>
                              layoutIndex.extentFor(
                                index,
                                currentIndex: currentIndex,
                                selectedMatch: widget.selectedSearchMatch,
                              ),
                          itemBuilder: (context, index) =>
                              _retainedScrollSpringRows.contains(index)
                              ? const SizedBox.expand()
                              : buildLyricRow(index),
                          motionFrame: _lyricMotionFrame,
                          overlayRowsBuilder: () => [
                            for (final index in _retainedScrollSpringRows)
                              buildLyricRow(index, positionedOverlay: true),
                          ],
                        ),
                      ),
                ),
                if (widget.showPlaybackLineControls)
                  _buildPlaybackLineControls(
                    lyrics: lyrics,
                    textWidth: textWidth,
                    sideColumnWidth: sideColumnWidth,
                    maxWidth: constraints.maxWidth,
                    maxHeight: constraints.maxHeight,
                    visibleHeight: visibleHeight,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _HighlightedLyricText extends StatelessWidget {
  const _HighlightedLyricText({
    super.key,
    required this.text,
    required this.query,
    required this.selectedMatch,
    required this.style,
  });

  final String text;
  final String query;
  final LyricSearchMatch? selectedMatch;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty ||
        !RegExp(
          RegExp.escape(normalizedQuery),
          caseSensitive: false,
          unicode: true,
        ).hasMatch(text)) {
      return Text(text, style: style, textAlign: TextAlign.center);
    }
    return Text.rich(
      _highlightedLyricSpan(
        text: text,
        query: query,
        selectedMatch: selectedMatch,
        style: style ?? const TextStyle(),
        colors: Theme.of(context).colorScheme,
      ),
      textAlign: TextAlign.center,
    );
  }
}

TextSpan _highlightedLyricSpan({
  required String text,
  required String query,
  required LyricSearchMatch? selectedMatch,
  required TextStyle style,
  required ColorScheme colors,
}) {
  final normalizedQuery = query.trim();
  if (normalizedQuery.isEmpty) return TextSpan(text: text, style: style);
  final expression = RegExp(
    RegExp.escape(normalizedQuery),
    caseSensitive: false,
    unicode: true,
  );
  final matches = expression.allMatches(text).toList(growable: false);
  if (matches.isEmpty) return TextSpan(text: text, style: style);
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final match in matches) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, match.start)));
    }
    final selected =
        selectedMatch?.start == match.start && selectedMatch?.end == match.end;
    spans.add(
      TextSpan(
        text: text.substring(match.start, match.end),
        style: TextStyle(
          color: selected ? colors.onPrimary : colors.primary,
          backgroundColor: selected ? colors.primary : null,
          // Search decoration must remain layout-neutral. A weight change can
          // reflow wrapped lyrics and make the scroll offset jump while the
          // search UI is opening or closing.
          fontWeight: style.fontWeight,
          shadows: selected
              ? [Shadow(color: colors.onPrimary, blurRadius: 0.45)]
              : null,
        ),
      ),
    );
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return TextSpan(style: style, children: spans);
}

FontWeight _fontWeight(int weight) {
  final index = ((weight.clamp(100, 900) / 100).round() - 1).clamp(0, 8);
  return FontWeight.values[index];
}
