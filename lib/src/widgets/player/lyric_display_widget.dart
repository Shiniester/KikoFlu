import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/lyric.dart';
import '../../providers/audio_provider.dart';
import '../../providers/lyric_provider.dart';
import '../../providers/player_lyric_style_provider.dart';
import '../../../l10n/app_localizations.dart';
import 'player_vertical_gestures.dart';

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

class FullLyricDisplayController {
  _FullLyricDisplayState? _state;

  void _attach(_FullLyricDisplayState state) => _state = state;

  void _detach(_FullLyricDisplayState state) {
    if (identical(_state, state)) _state = null;
  }

  void scrollToIndex(int index, {bool animate = true}) {
    _state?._scrollToLyric(
      index,
      animate: animate,
      force: true,
      ignoreAutoScroll: true,
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
    this.selectedSearchIndex,
    this.topPadding = 72,
    this.bottomPadding = 148,
    this.snapToCurrentOnFirstLayout = false,
    this.onSeekRequested,
    this.onDismissPlayer,
    this.onShowQueue,
  });

  final Duration? seekingPosition;
  final bool isPortrait;
  final bool isLocked;
  final VoidCallback? onLongPress;
  final FullLyricDisplayController? controller;
  final bool suspendAutoScroll;
  final String searchQuery;
  final int? selectedSearchIndex;
  final double topPadding;
  final double bottomPadding;
  final bool snapToCurrentOnFirstLayout;
  final ValueChanged<Duration>? onSeekRequested;
  final VoidCallback? onDismissPlayer;
  final VoidCallback? onShowQueue;

  @override
  ConsumerState<FullLyricDisplay> createState() => _FullLyricDisplayState();
}

class _FullLyricDisplayState extends ConsumerState<FullLyricDisplay> {
  final ScrollController _scrollController = ScrollController();
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
  }) {
    if ((!_autoScroll || widget.suspendAutoScroll) && !ignoreAutoScroll) return;
    if (!_scrollController.hasClients || index < 0) return;
    final duration = MediaQuery.disableAnimationsOf(context) || !animate
        ? Duration.zero
        : const Duration(milliseconds: 460);
    final request = ++_scrollRequestGeneration;
    unawaited(
      _performLyricScroll(
        index: index,
        duration: duration,
        force: force,
        request: request,
      ),
    );
  }

  Future<void> _performLyricScroll({
    required int index,
    required Duration duration,
    required bool force,
    required int request,
  }) async {
    if (!mounted ||
        request != _scrollRequestGeneration ||
        !_scrollController.hasClients) {
      return;
    }
    final itemContext = _getKeyForIndex(index).currentContext;
    final renderObject = itemContext?.findRenderObject();
    if (renderObject != null) {
      await _ensureVisibleInsideLyricList(renderObject, duration);
      return;
    }
    if (!force) return;

    final lyrics = ref.read(lyricControllerProvider).displayLyrics;
    final viewport = _scrollController.position.viewportDimension;
    final target = (_estimatedOffset(index, lyrics) - viewport * 0.42).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
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
    if (correctedRenderObject != null) {
      await _ensureVisibleInsideLyricList(
        correctedRenderObject,
        duration == Duration.zero
            ? Duration.zero
            : const Duration(milliseconds: 180),
      );
    }
  }

  Future<void> _ensureVisibleInsideLyricList(
    RenderObject renderObject,
    Duration duration,
  ) async {
    if (!_scrollController.hasClients) return;
    try {
      // Static Scrollable.ensureVisible also drives ancestor PageViews. Keep
      // lyric positioning confined to this list so the player stage is fixed.
      await _scrollController.position.ensureVisible(
        renderObject,
        alignment: 0.5,
        duration: duration,
        curve: Curves.easeOutCubic,
      );
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
      child: PlayerScrollEdgeActions(
        onPullDownAtTop: widget.onDismissPlayer,
        onPushUpAtBottom: widget.onShowQueue,
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
                    selectedMatch: widget.selectedSearchIndex == index,
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
  final bool selectedMatch;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty ||
        !text.toLowerCase().contains(normalizedQuery.toLowerCase())) {
      return Text(text, style: style, textAlign: TextAlign.center);
    }
    final spans = <InlineSpan>[];
    final lowerText = text.toLowerCase();
    final lowerQuery = normalizedQuery.toLowerCase();
    var cursor = 0;
    while (cursor < text.length) {
      final index = lowerText.indexOf(lowerQuery, cursor);
      if (index < 0) {
        spans.add(TextSpan(text: text.substring(cursor)));
        break;
      }
      if (index > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, index)));
      }
      spans.add(
        TextSpan(
          text: text.substring(index, index + normalizedQuery.length),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: selectedMatch ? FontWeight.w900 : FontWeight.w800,
          ),
        ),
      );
      cursor = index + normalizedQuery.length;
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
