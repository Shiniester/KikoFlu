import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderBox, RenderParagraph, ScrollCacheExtent, ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/lyric.dart';
import '../../providers/audio_provider.dart';
import '../../providers/lyric_provider.dart';
import '../../providers/player_lyric_style_provider.dart';
import '../../../l10n/app_localizations.dart';

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
    this.onTap,
    this.compact = false,
    this.lineCount = 3,
  }) : assert(lineCount == 3 || lineCount == 5);

  final VoidCallback? onTap;
  final bool compact;
  final int lineCount;

  @override
  ConsumerState<ThreeLineLyricDisplay> createState() =>
      _ThreeLineLyricDisplayState();
}

class _ThreeLineLyricDisplayState extends ConsumerState<ThreeLineLyricDisplay> {
  final ScrollController _scrollController = ScrollController();
  Timer? _resumeFollowTimer;
  bool _isUserBrowsing = false;
  bool _userScrollInProgress = false;
  int _latestIndex = -1;
  int? _lastIndex;
  int? _lyricsSignature;
  int _scrollGeneration = 0;
  double? _lastItemExtent;

  @override
  void dispose() {
    _resumeFollowTimer?.cancel();
    _scrollGeneration++;
    _scrollController.dispose();
    super.dispose();
  }

  void _positionCurrentLine(
    int index,
    double itemExtent, {
    required bool animate,
    Duration duration = const Duration(milliseconds: 460),
    bool deferUntilLayout = true,
  }) {
    final generation = ++_scrollGeneration;
    Future<void> position() async {
      if (!mounted ||
          generation != _scrollGeneration ||
          !_scrollController.hasClients) {
        return;
      }
      final target = (index * itemExtent).clamp(
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
    _resumeFollowTimer?.cancel();
    _resumeFollowTimer = Timer(const Duration(seconds: 2), () {
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
    final index = ref.watch(currentLyricIndexProvider);
    final settings = ref.watch(playerLyricSettingsProvider);
    if (lyrics.isEmpty) {
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

    final previewHeight = widget.compact
        ? 70.0
        : (widget.lineCount == 5 ? 144.0 : 100.0);
    final itemExtent = (settings.smallFontSize * settings.smallLineHeight + 11)
        .clamp(25.0, 31.0);
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
      _lyricsSignature = signature;
      _lastIndex = null;
    }
    _latestIndex = index;
    final itemExtentChanged = _lastItemExtent != itemExtent;
    _lastItemExtent = itemExtent;
    if (index >= 0 &&
        (index != _lastIndex || sourceChanged || itemExtentChanged)) {
      final animate = _lastIndex != null && !sourceChanged;
      _lastIndex = index;
      if (!_isUserBrowsing) {
        _positionCurrentLine(index, itemExtent, animate: animate);
      }
    }

    return Semantics(
      button: widget.onTap != null,
      label: index >= 0 && index < lyrics.length ? lyrics[index].text : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: widget.onTap,
        child: SizedBox(
          key: ValueKey('compact-lyric-preview-${widget.lineCount}-lines'),
          height: previewHeight,
          child: ClipRect(
            child: RepaintBoundary(
              child: NotificationListener<UserScrollNotification>(
                onNotification: _handleUserScrollNotification,
                child: ListView.builder(
                  key: const ValueKey('compact-lyric-scroll-list'),
                  controller: _scrollController,
                  physics: const ClampingScrollPhysics(),
                  itemExtent: itemExtent,
                  scrollCacheExtent: ScrollCacheExtent.pixels(previewHeight),
                  padding: EdgeInsets.symmetric(
                    vertical: (previewHeight - itemExtent) / 2,
                  ),
                  itemCount: lyrics.length,
                  itemBuilder: (context, lyricIndex) {
                    final distance = (lyricIndex - index).abs();
                    final active = distance == 0;
                    return Center(
                      child: _PreviewLine(
                        text: lyrics[lyricIndex].text,
                        fontSize: active
                            ? settings.smallFontSize + (widget.compact ? 0 : 1)
                            : settings.smallFontSize - 1,
                        lineHeight: settings.smallLineHeight,
                        opacity: active ? 1 : (distance == 1 ? 0.56 : 0.36),
                        fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                        maxLines: 1,
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
  }
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

  static const double itemVerticalPadding = 24;

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
    final painter = TextPainter(
      text: _highlightedLyricSpan(
        text: text,
        query: query,
        selectedMatch: selectedMatch,
        style: active ? activeStyle : inactiveStyle,
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
    final layout = _LyricLineLayout(
      extent: painter.height + itemVerticalPadding,
      matchCenterY: 12 + matchCenterY,
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
}

class FullLyricDisplay extends ConsumerStatefulWidget {
  const FullLyricDisplay({
    super.key,
    this.seekingPosition,
    this.isPortrait = false,
    this.isLocked = false,
    this.onLongPress,
    this.controller,
    this.suspendAutoScroll = false,
    this.searchMode = false,
    this.searchQuery = '',
    this.selectedSearchMatch,
    this.topPadding = 72,
    this.bottomPadding = 148,
    this.visibleBottomInset = 0,
    this.snapToCurrentOnFirstLayout = false,
    this.onSeekRequested,
  });

  final Duration? seekingPosition;
  final bool isPortrait;
  final bool isLocked;
  final VoidCallback? onLongPress;
  final FullLyricDisplayController? controller;
  final bool suspendAutoScroll;
  final bool searchMode;
  final String searchQuery;
  final LyricSearchMatch? selectedSearchMatch;
  final double topPadding;
  final double bottomPadding;
  final double visibleBottomInset;
  final bool snapToCurrentOnFirstLayout;
  final ValueChanged<Duration>? onSeekRequested;

  @override
  ConsumerState<FullLyricDisplay> createState() => _FullLyricDisplayState();
}

class _FullLyricDisplayState extends ConsumerState<FullLyricDisplay> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  final Map<int, GlobalKey> _itemKeys = {};
  final Map<int, GlobalKey> _textKeys = {};
  int? _currentLyricIndex;
  bool _autoScroll = true;
  Timer? _resumeAutoScrollTimer;
  int _scrollRequestGeneration = 0;
  int? _lyricsSignature;
  int? _layoutFingerprint;
  _LyricLayoutIndex? _layoutIndex;
  double _effectiveTopPadding = 0;
  int _layoutCurrentIndex = -1;
  LyricSearchMatch? _layoutSelectedMatch;
  bool _hasLayoutMetrics = false;
  int _paddingCompensationGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(covariant FullLyricDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (!oldWidget.suspendAutoScroll && widget.suspendAutoScroll) {
      _scrollRequestGeneration++;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.pixels);
      }
    }
    if (oldWidget.suspendAutoScroll && !widget.suspendAutoScroll) {
      final index = _currentLyricIndex;
      if (index != null && index >= 0) {
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
  }

  @override
  void dispose() {
    _scrollRequestGeneration++;
    _paddingCompensationGeneration++;
    widget.controller?._detach(this);
    _resumeAutoScrollTimer?.cancel();
    _scrollController.dispose();
    _itemKeys.clear();
    _textKeys.clear();
    super.dispose();
  }

  GlobalKey _getKeyForIndex(int index) {
    return _itemKeys.putIfAbsent(index, GlobalKey.new);
  }

  GlobalKey _getTextKeyForIndex(int index) {
    return _textKeys.putIfAbsent(index, GlobalKey.new);
  }

  void _updateEffectiveTopPadding(double nextPadding) {
    final previousPadding = _effectiveTopPadding;
    _effectiveTopPadding = nextPadding;
    if (!_hasLayoutMetrics) {
      _hasLayoutMetrics = true;
      return;
    }
    final delta = nextPadding - previousPadding;
    if (delta.abs() <= 0.01) return;
    final request = ++_paddingCompensationGeneration;
    if (delta <= 0.01 || !_scrollController.hasClients) return;
    final startingOffset = _scrollController.position.pixels;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          request != _paddingCompensationGeneration ||
          !_scrollController.hasClients) {
        return;
      }
      _scrollController.jumpTo(
        (startingOffset + delta).clamp(
          _scrollController.position.minScrollExtent,
          _scrollController.position.maxScrollExtent,
        ),
      );
    });
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
      textScaler.scale(16),
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

  double? _layoutTargetForLine(int index, double visibleBottomInset) {
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
        layout.extent / 2;
    return (center - _visibleViewportHeight(visibleBottomInset) / 2).clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
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
    return (matchCenter - _visibleViewportHeight(visibleBottomInset) / 2).clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
  }

  void _scrollToLyric(
    int index, {
    bool animate = true,
    bool force = false,
    bool ignoreAutoScroll = false,
    double? visibleBottomInset,
    Duration? animationDuration,
  }) {
    if ((!_autoScroll || widget.suspendAutoScroll) && !ignoreAutoScroll) return;
    if (!_scrollController.hasClients || index < 0) return;
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
      ),
    );
  }

  Future<void> _performLyricScroll({
    required int index,
    required Duration duration,
    required bool force,
    required int request,
    required double visibleBottomInset,
  }) async {
    if (!mounted ||
        request != _scrollRequestGeneration ||
        !_scrollController.hasClients) {
      return;
    }
    final itemContext = _getKeyForIndex(index).currentContext;
    final renderObject = itemContext?.findRenderObject();
    if (renderObject is RenderBox) {
      await _centerInsideVisibleViewport(
        renderObject,
        duration,
        visibleBottomInset,
      );
      return;
    }
    if (!force) return;

    final target = _layoutTargetForLine(index, visibleBottomInset);
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
      await _centerInsideVisibleViewport(
        correctedRenderObject,
        duration == Duration.zero
            ? Duration.zero
            : const Duration(milliseconds: 120),
        visibleBottomInset,
      );
    }
  }

  void _scrollToMatch(
    LyricSearchMatch match, {
    required bool animate,
    required double Function() visibleBottomInset,
  }) {
    if (!_scrollController.hasClients || match.lineIndex < 0) return;
    final request = ++_scrollRequestGeneration;
    unawaited(
      _performMatchScroll(
        match: match,
        animate: animate,
        request: request,
        visibleBottomInset: visibleBottomInset,
      ),
    );
  }

  Future<void> _performMatchScroll({
    required LyricSearchMatch match,
    required bool animate,
    required int request,
    required double Function() visibleBottomInset,
  }) async {
    if (!mounted ||
        request != _scrollRequestGeneration ||
        !_scrollController.hasClients) {
      return;
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
            _visibleViewportHeight(visibleBottomInset) / 2)
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

  Future<void> _centerInsideVisibleViewport(
    RenderBox item,
    Duration duration,
    double visibleBottomInset,
  ) async {
    if (!_scrollController.hasClients) return;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !item.attached || !viewport.attached) return;
    final itemCenter = item.localToGlobal(
      item.size.center(Offset.zero),
      ancestor: viewport,
    );
    final target =
        (_scrollController.position.pixels +
                itemCenter.dy -
                _visibleViewportHeight(visibleBottomInset) / 2)
            .clamp(
              _scrollController.position.minScrollExtent,
              _scrollController.position.maxScrollExtent,
            );
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
    if (widget.onSeekRequested case final callback?) {
      callback(target);
    } else {
      ref.read(audioPlayerControllerProvider.notifier).seekAndPersist(target);
    }
    _resumeAutoScrollTimer?.cancel();
    setState(() => _autoScroll = false);
    _scrollToLyric(index, force: true, ignoreAutoScroll: true);
    _resumeAutoScrollTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _autoScroll = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = ref.watch(
      lyricControllerProvider.select((state) => state.displayLyrics),
    );
    final playbackIndex = ref.watch(currentLyricIndexProvider);
    final settings = ref.watch(playerLyricSettingsProvider);
    if (lyrics.isEmpty) {
      return Center(child: Text(S.of(context).noSubtitlesAvailable));
    }
    final signature = Object.hash(
      lyrics.length,
      lyrics.first.startTime,
      lyrics.first.text,
      lyrics.last.startTime,
      lyrics.last.text,
    );
    if (_lyricsSignature != signature) {
      _lyricsSignature = signature;
      _scrollRequestGeneration++;
      _currentLyricIndex = null;
      _itemKeys.clear();
      _textKeys.clear();
      _layoutFingerprint = null;
      _layoutIndex = null;
    }
    final currentIndex = widget.seekingPosition == null
        ? playbackIndex
        : _indexForPosition(widget.seekingPosition!, lyrics);

    if (currentIndex != _currentLyricIndex && currentIndex >= 0) {
      final previous = _currentLyricIndex;
      _currentLyricIndex = currentIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollToLyric(
          currentIndex,
          animate:
              widget.seekingPosition == null &&
              !(widget.snapToCurrentOnFirstLayout && previous == null),
          force: previous == null || (currentIndex - previous).abs() > 5,
        );
      });
    }

    return GestureDetector(
      onLongPress: widget.onLongPress,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
          final baseStyle = theme.textTheme.bodyLarge ?? const TextStyle();
          final weight = _fontWeight(settings.fullFontWeight);
          final activeStyle = baseStyle.copyWith(
            color: colors.onSurface,
            fontWeight: weight,
            fontSize: settings.fullActiveFontSize,
            height: settings.fullLineHeight,
          );
          final inactiveStyle = baseStyle.copyWith(
            color: colors.onSurface.withValues(alpha: 0.34),
            fontWeight: weight,
            fontSize: settings.fullInactiveFontSize,
            height: settings.fullLineHeight,
          );
          final textScaler = MediaQuery.textScalerOf(context);
          final textDirection = Directionality.of(context);
          final locale = Localizations.maybeLocaleOf(context);
          final textWidth = math.max(1.0, constraints.maxWidth - 80);
          final normalizedQuery = widget.searchQuery.trim();
          final layoutIndex = _ensureLayoutIndex(
            lyrics: lyrics,
            query: normalizedQuery,
            activeStyle: activeStyle,
            inactiveStyle: inactiveStyle,
            colors: colors,
            textWidth: textWidth,
            textScaler: textScaler,
            textDirection: textDirection,
            locale: locale,
          );
          final hasSearchAllowance = widget.searchMode;
          final effectiveTopPadding = hasSearchAllowance
              ? math.max(widget.topPadding, constraints.maxHeight / 2)
              : widget.topPadding;
          final effectiveBottomPadding = hasSearchAllowance
              ? math.max(widget.bottomPadding, constraints.maxHeight)
              : widget.bottomPadding;
          _updateEffectiveTopPadding(effectiveTopPadding);
          _layoutCurrentIndex = currentIndex;
          _layoutSelectedMatch = widget.selectedSearchMatch;

          return SizedBox.expand(
            key: _viewportKey,
            child: ListView.builder(
              key: const ValueKey('full-lyric-list'),
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              ),
              padding: EdgeInsets.fromLTRB(
                24,
                effectiveTopPadding,
                24,
                effectiveBottomPadding,
              ),
              itemCount: lyrics.length,
              itemExtentBuilder: (index, dimensions) => layoutIndex.extentFor(
                index,
                currentIndex: currentIndex,
                selectedMatch: widget.selectedSearchMatch,
              ),
              itemBuilder: (context, index) {
                final lyric = lyrics[index];
                final active = index == currentIndex;
                final past = index < currentIndex;
                final style = (active ? activeStyle : inactiveStyle).copyWith(
                  color: colors.onSurface.withValues(
                    alpha: active ? 1 : (past ? 0.24 : 0.34),
                  ),
                );
                return Semantics(
                  selected: active,
                  button: !widget.isLocked,
                  child: InkWell(
                    key: _getKeyForIndex(index),
                    borderRadius: BorderRadius.circular(12),
                    onTap: widget.isLocked
                        ? null
                        : () => _onLyricTap(index, lyrics),
                    onLongPress: widget.onLongPress,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 16,
                      ),
                      child: _HighlightedLyricText(
                        key: _getTextKeyForIndex(index),
                        text: lyric.text,
                        query: normalizedQuery,
                        selectedMatch:
                            widget.selectedSearchMatch?.lineIndex == index
                            ? widget.selectedSearchMatch
                            : null,
                        style: style,
                      ),
                    ),
                  ),
                );
              },
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
          fontWeight: selected ? FontWeight.w900 : FontWeight.w800,
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
