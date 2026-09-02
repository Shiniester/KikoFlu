import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderBox, ScrollCacheExtent;
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
  int? _lastIndex;
  int? _lyricsSignature;
  int _scrollGeneration = 0;
  double? _lastItemExtent;

  @override
  void dispose() {
    _scrollGeneration++;
    _scrollController.dispose();
    super.dispose();
  }

  void _positionCurrentLine(
    int index,
    double itemExtent, {
    required bool animate,
  }) {
    final generation = ++_scrollGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
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
          duration: const Duration(milliseconds: 460),
          curve: Curves.easeOutCubic,
        );
      } catch (_) {
        // A horizontal page or queue transition may detach the preview.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = ref.watch(
      lyricControllerProvider.select((state) => state.displayLyrics),
    );
    final index = ref.watch(currentLyricIndexProvider);
    final settings = ref.watch(playerLyricSettingsProvider);
    if (lyrics.isEmpty) {
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
      _lyricsSignature = signature;
      _lastIndex = null;
    }
    final itemExtentChanged = _lastItemExtent != itemExtent;
    _lastItemExtent = itemExtent;
    if (index >= 0 &&
        (index != _lastIndex || sourceChanged || itemExtentChanged)) {
      final animate = _lastIndex != null && !sourceChanged;
      _lastIndex = index;
      _positionCurrentLine(index, itemExtent, animate: animate);
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
              child: ListView.builder(
                key: const ValueKey('compact-lyric-scroll-list'),
                controller: _scrollController,
                physics: const NeverScrollableScrollPhysics(),
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

class FullLyricDisplayController {
  _FullLyricDisplayState? _state;

  void _attach(_FullLyricDisplayState state) => _state = state;

  void _detach(_FullLyricDisplayState state) {
    if (identical(_state, state)) _state = null;
  }

  void centerOnIndex(
    int index, {
    bool animate = true,
    double visibleBottomInset = 0,
  }) {
    _state?._scrollToLyric(
      index,
      animate: animate,
      force: true,
      ignoreAutoScroll: true,
      visibleBottomInset: visibleBottomInset,
      animationDuration: const Duration(milliseconds: 280),
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
  int? _currentLyricIndex;
  bool _autoScroll = true;
  Timer? _resumeAutoScrollTimer;
  int _scrollRequestGeneration = 0;
  int? _lyricsSignature;

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
    widget.controller?._detach(this);
    _resumeAutoScrollTimer?.cancel();
    _scrollController.dispose();
    _itemKeys.clear();
    super.dispose();
  }

  GlobalKey _getKeyForIndex(int index) {
    return _itemKeys.putIfAbsent(index, GlobalKey.new);
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

  double _estimateItemHeight(String text, bool active) {
    final settings = ref.read(playerLyricSettingsProvider);
    final width = MediaQuery.sizeOf(context).width;
    final areaWidth = widget.isPortrait ? width - 64 : width * 0.48 - 48;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: active
              ? settings.fullActiveFontSize
              : settings.fullInactiveFontSize,
          fontWeight: _fontWeight(settings.fullFontWeight),
          height: settings.fullLineHeight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: areaWidth.clamp(120, double.infinity));
    return painter.height + 32;
  }

  double _estimatedOffset(int targetIndex, List<LyricLine> lyrics) {
    var offset = widget.topPadding;
    for (var index = 0; index < targetIndex && index < lyrics.length; index++) {
      offset += _estimateItemHeight(lyrics[index].text, false);
    }
    return offset;
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

    final lyrics = ref.read(lyricControllerProvider).displayLyrics;
    if (index >= lyrics.length) return;
    final visibleHeight = _visibleViewportHeight(visibleBottomInset);
    final target =
        (_estimatedOffset(index, lyrics) +
                _estimateItemHeight(lyrics[index].text, false) / 2 -
                visibleHeight / 2)
            .clamp(0.0, _scrollController.position.maxScrollExtent);
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
      child: SizedBox.expand(
        key: _viewportKey,
        child: ListView.builder(
          key: const ValueKey('full-lyric-list'),
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            24,
            widget.topPadding,
            24,
            widget.bottomPadding,
          ),
          itemCount: lyrics.length,
          itemBuilder: (context, index) {
            final lyric = lyrics[index];
            final active = index == currentIndex;
            final past = index < currentIndex;
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
                    text: lyric.text,
                    query: widget.searchQuery,
                    selectedMatch:
                        widget.selectedSearchMatch?.lineIndex == index
                        ? widget.selectedSearchMatch
                        : null,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withValues(
                        alpha: active ? 1 : (past ? 0.24 : 0.34),
                      ),
                      fontWeight: _fontWeight(settings.fullFontWeight),
                      fontSize: active
                          ? settings.fullActiveFontSize
                          : settings.fullInactiveFontSize,
                      height: settings.fullLineHeight,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HighlightedLyricText extends StatelessWidget {
  const _HighlightedLyricText({
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
    if (normalizedQuery.isEmpty) {
      return Text(text, style: style, textAlign: TextAlign.center);
    }
    final expression = RegExp(
      RegExp.escape(normalizedQuery),
      caseSensitive: false,
      unicode: true,
    );
    final matches = expression.allMatches(text).toList(growable: false);
    if (matches.isEmpty) {
      return Text(text, style: style, textAlign: TextAlign.center);
    }
    final spans = <InlineSpan>[];
    var cursor = 0;
    final colors = Theme.of(context).colorScheme;
    for (final match in matches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final selected =
          selectedMatch?.start == match.start &&
          selectedMatch?.end == match.end;
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
    return Text.rich(
      TextSpan(style: style, children: spans),
      textAlign: TextAlign.center,
    );
  }
}

FontWeight _fontWeight(int weight) {
  final index = ((weight.clamp(100, 900) / 100).round() - 1).clamp(0, 8);
  return FontWeight.values[index];
}
