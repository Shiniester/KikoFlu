import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/lyric_provider.dart';
import '../../providers/player_lyric_style_provider.dart';
import 'lyric_display_widget.dart';
import 'player_glass_surface.dart';
import 'player_vertical_gestures.dart';

class PlayerLyricsSurface extends ConsumerStatefulWidget {
  const PlayerLyricsSurface({
    super.key,
    required this.isWide,
    required this.onFullscreen,
    required this.translateButton,
    this.isActive = true,
    this.seekingPosition,
    this.onDownload,
    this.onLongPress,
    this.onShowQueue,
    this.showQueueDrag,
    this.actionWidth,
  });

  final bool isWide;
  final Duration? seekingPosition;
  final VoidCallback onFullscreen;
  final Widget translateButton;
  final bool isActive;
  final VoidCallback? onDownload;
  final VoidCallback? onLongPress;
  final VoidCallback? onShowQueue;
  final PlayerVerticalDragCallbacks? showQueueDrag;
  final double? actionWidth;

  @override
  ConsumerState<PlayerLyricsSurface> createState() =>
      _PlayerLyricsSurfaceState();
}

class _PlayerLyricsSurfaceState extends ConsumerState<PlayerLyricsSurface>
    with SingleTickerProviderStateMixin {
  final FullLyricDisplayController _displayController =
      FullLyricDisplayController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  late final AnimationController _searchRevealController;
  bool _searching = false;
  bool _searchClosing = false;
  List<LyricSearchMatch> _matches = const [];
  int _matchCursor = -1;
  int _matchCenterGeneration = 0;
  int? _matchedLyricsSignature;
  double _currentVisibleBottomInset = 0;

  @override
  void initState() {
    super.initState();
    _searchRevealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      reverseDuration: const Duration(milliseconds: 140),
    );
  }

  @override
  void dispose() {
    _matchCenterGeneration++;
    _searchRevealController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(lyricControllerProvider);
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final query = _searchController.text.trim();
    if (_searching && query.isNotEmpty) {
      final signature = _lyricTextSignature(state);
      if (_matchedLyricsSignature != signature) {
        _matchedLyricsSignature = signature;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _searching &&
              _searchController.text.trim().isNotEmpty) {
            _updateMatches(ref.read(lyricControllerProvider));
          }
        });
      }
    }
    final mediaQuery = MediaQuery.of(context);
    const actionRowHeight = 48.0;
    const searchRowHeight = 56.0;
    const viewportClearance = 4.0;
    final keyboardInset = _searching ? mediaQuery.viewInsets.bottom : 0.0;
    final keyboardLift = keyboardInset > mediaQuery.padding.bottom
        ? keyboardInset - mediaQuery.padding.bottom
        : 0.0;
    final controlsBottom = 14.0 + mediaQuery.padding.bottom;
    final selectedMatch = _matchCursor >= 0 && _matchCursor < _matches.length
        ? _matches[_matchCursor]
        : null;
    final queueDrag = _queueDragCallbacks;
    final baseVisibleBottomInset =
        controlsBottom + actionRowHeight + viewportClearance;
    return RepaintBoundary(
      key: ValueKey('player-lyrics-surface-${widget.isWide}'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return AnimatedBuilder(
            animation: _searchRevealController,
            builder: (context, _) {
              final revealedSearchHeight =
                  searchRowHeight * _searchRevealController.value;
              final requestedViewportBottom =
                  controlsBottom +
                  keyboardLift +
                  actionRowHeight +
                  revealedSearchHeight +
                  viewportClearance;
              final lyricViewportBottom = requestedViewportBottom.clamp(
                0.0,
                (constraints.maxHeight - 1).clamp(0.0, double.infinity),
              );
              _currentVisibleBottomInset = lyricViewportBottom;
              final bottomControls = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    key: ValueKey('lyric-bottom-queue-blank'),
                    width: double.infinity,
                    height: viewportClearance,
                  ),
                  Column(
                    key: const ValueKey('lyric-controls-keyboard-lift'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_searching)
                        SizeTransition(
                          sizeFactor: _searchRevealController,
                          alignment: Alignment.bottomCenter,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: _buildSearchBar(context, state),
                          ),
                        ),
                      SizedBox(
                        key: const ValueKey('lyric-actions-width-boundary'),
                        width: widget.actionWidth ?? double.infinity,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _ActionButton(
                              key: const ValueKey('lyric-settings-button'),
                              icon: Icons.text_fields,
                              label: _label(context, 'settings'),
                              onPressed: () => _showSettings(context),
                            ),
                            _ActionButton(
                              key: const ValueKey('lyric-download-button'),
                              icon: Icons.download_outlined,
                              label: widget.onDownload == null
                                  ? _label(context, 'downloadUnavailable')
                                  : _label(context, 'download'),
                              onPressed: widget.onDownload,
                            ),
                            _ActionButton(
                              key: const ValueKey('lyric-fullscreen-button'),
                              icon: Icons.fullscreen,
                              label: _label(context, 'fullscreen'),
                              onPressed: state.lyrics.isEmpty
                                  ? null
                                  : widget.onFullscreen,
                            ),
                            Semantics(
                              key: const ValueKey('lyric-translate-button'),
                              label: _label(context, 'translate'),
                              button: true,
                              child: SizedBox(
                                width: 48,
                                child: widget.translateButton,
                              ),
                            ),
                            _ActionButton(
                              key: const ValueKey('lyric-search-button'),
                              icon: _searching ? Icons.close : Icons.search,
                              label: _label(context, 'search'),
                              onPressed: state.lyrics.isEmpty
                                  ? null
                                  : _toggleSearch,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              );
              return Stack(
                children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    right: 0,
                    bottom: lyricViewportBottom,
                    child: ClipRect(
                      key: const ValueKey('lyric-keyboard-safe-viewport'),
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        minWidth: constraints.maxWidth,
                        maxWidth: constraints.maxWidth,
                        minHeight: constraints.maxHeight,
                        maxHeight: constraints.maxHeight,
                        child: SizedBox(
                          width: constraints.maxWidth,
                          height: constraints.maxHeight,
                          child: RepaintBoundary(
                            child: ShaderMask(
                              key: const ValueKey('lyric-edge-fade-mask'),
                              blendMode: BlendMode.dstIn,
                              shaderCallback: (bounds) => _lyricFadeGradient(
                                bounds,
                                lyricViewportBottom,
                              ).createShader(bounds),
                              child: FullLyricDisplay(
                                controller: _displayController,
                                seekingPosition: widget.seekingPosition,
                                isPortrait: !widget.isWide,
                                onLongPress: widget.onLongPress,
                                suspendAutoScroll:
                                    _searching || !widget.isActive,
                                searchMode: _searching,
                                searchQuery: _searchController.text,
                                selectedSearchMatch: selectedMatch,
                                topPadding: 86,
                                bottomPadding: widget.isWide ? 136 : 164,
                                visibleBottomInset: baseVisibleBottomInset,
                                snapToCurrentOnFirstLayout: true,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: controlsBottom,
                    child: Transform.translate(
                      key: const ValueKey('lyric-keyboard-controls-transform'),
                      offset: Offset(0, -keyboardLift),
                      child: RepaintBoundary(
                        child: PlayerVerticalSwipeRegion(
                          key: const ValueKey(
                            'lyric-bottom-queue-swipe-surface',
                          ),
                          onSwipeUp: widget.onShowQueue == null
                              ? null
                              : _showQueue,
                          swipeUpDrag: queueDrag,
                          child: bottomControls,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  LinearGradient _lyricFadeGradient(Rect bounds, double bottomInset) {
    if (bounds.height <= 0) {
      return const LinearGradient(colors: [Colors.transparent, Colors.white]);
    }
    final visibleEnd = ((bounds.height - bottomInset) / bounds.height)
        .clamp(0.02, 1.0)
        .toDouble();
    final topOpaque = (48 / bounds.height)
        .clamp(0.0, visibleEnd * 0.35)
        .toDouble();
    final fadeHeight = (72 / bounds.height)
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

  int _lyricTextSignature(LyricState state) {
    final lyrics = state.displayLyrics;
    return Object.hash(
      state.showTranslated,
      lyrics.length,
      Object.hashAll(lyrics.map((line) => line.text)),
    );
  }

  PlayerVerticalDragCallbacks? get _queueDragCallbacks {
    final drag = widget.showQueueDrag;
    if (drag == null) return null;
    return PlayerVerticalDragCallbacks(
      onStart: () {
        _searchFocusNode.unfocus();
        drag.onStart();
      },
      onUpdate: drag.onUpdate,
      onEnd: drag.onEnd,
      onCancel: drag.onCancel,
    );
  }

  void _showQueue() {
    _searchFocusNode.unfocus();
    widget.onShowQueue?.call();
  }

  Widget _buildSearchBar(BuildContext context, LyricState state) {
    final countLabel = _matches.isEmpty
        ? '0/0'
        : '${_matchCursor + 1}/${_matches.length}';
    return Align(
      key: const ValueKey('lyric-search-center-boundary'),
      alignment: Alignment.center,
      child: SizedBox(
        key: const ValueKey('lyric-search-width-boundary'),
        width: widget.actionWidth ?? double.infinity,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: PlayerTransientGlassSurface(
            borderRadius: BorderRadius.circular(14),
            child: Row(
              children: [
                const SizedBox(width: 12),
                const Icon(Icons.search, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const ValueKey('lyric-search-field'),
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    textAlign: TextAlign.start,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: _label(context, 'searchHint'),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onChanged: (_) => _updateMatches(state),
                  ),
                ),
                Text(
                  countLabel,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                IconButton(
                  tooltip: _label(context, 'previous'),
                  onPressed: _matches.isEmpty ? null : () => _moveMatch(-1),
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton(
                  tooltip: _label(context, 'next'),
                  onPressed: _matches.isEmpty ? null : () => _moveMatch(1),
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggleSearch() async {
    if (!_searching) {
      setState(() {
        _searching = true;
        _searchClosing = false;
      });
      _searchRevealController.stop();
      if (MediaQuery.disableAnimationsOf(context)) {
        _searchRevealController.value = 1;
      } else {
        unawaited(
          _searchRevealController.animateTo(
            1,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
          ),
        );
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocusNode.requestFocus();
      });
      return;
    }
    if (_searchClosing) return;
    _searchClosing = true;
    _searchFocusNode.unfocus();
    _matchCenterGeneration++;
    setState(() {
      _searchController.clear();
      _matches = const [];
      _matchCursor = -1;
      _matchedLyricsSignature = null;
    });
    _searchRevealController.stop();
    if (MediaQuery.disableAnimationsOf(context)) {
      _searchRevealController.value = 0;
    } else {
      try {
        await _searchRevealController.animateTo(
          0,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeInCubic,
        );
      } catch (_) {
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _searching = false;
      _searchClosing = false;
    });
  }

  void _updateMatches(LyricState state) {
    final matches = findLyricSearchMatches(
      state.displayLyrics,
      _searchController.text,
    );
    setState(() {
      _matches = matches;
      _matchCursor = matches.isEmpty ? -1 : 0;
      _matchedLyricsSignature = _lyricTextSignature(state);
    });
    if (matches.isNotEmpty) _centerSelectedMatch();
  }

  void _moveMatch(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _matchCursor = (_matchCursor + delta) % _matches.length;
      if (_matchCursor < 0) _matchCursor += _matches.length;
    });
    _centerSelectedMatch();
  }

  void _centerSelectedMatch() {
    if (_matchCursor < 0 || _matchCursor >= _matches.length) return;
    final request = ++_matchCenterGeneration;
    final match = _matches[_matchCursor];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _matchCenterGeneration) return;
      _displayController.centerOnMatch(
        match,
        visibleBottomInset: () => _currentVisibleBottomInset,
      );
    });
  }

  Future<void> _showSettings(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (_) => const PlayerBackdropGroup(
        child: PlayerTransientGlassSurface(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          child: _LyricSettingsSheet(),
        ),
      ),
    );
  }
}

class _LyricSettingsSheet extends ConsumerWidget {
  const _LyricSettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(playerLyricSettingsProvider);
    final controller = ref.read(playerLyricSettingsProvider.notifier);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _label(context, 'lyricStyle'),
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            _SettingSlider(
              label: _label(context, 'fontSize'),
              valueLabel: settings.fullActiveFontSize.toStringAsFixed(0),
              value: settings.fullActiveFontSize,
              min: 12,
              max: 32,
              divisions: 20,
              onChanged: controller.updateFullFontSize,
            ),
            _SettingSlider(
              label: _label(context, 'fontWeight'),
              valueLabel: settings.fullFontWeight.toString(),
              value: settings.fullFontWeight.toDouble(),
              min: 100,
              max: 900,
              divisions: 8,
              onChanged: (value) =>
                  controller.updateFullFontWeight(value.round()),
            ),
            _SettingSlider(
              label: _label(context, 'lineHeight'),
              valueLabel: settings.fullLineHeight.toStringAsFixed(1),
              value: settings.fullLineHeight,
              min: 1,
              max: 2.2,
              divisions: 12,
              onChanged: controller.updateFullLineHeight,
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: controller.reset,
                child: Text(_label(context, 'reset')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 76, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: valueLabel,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 42, child: Text(valueLabel, textAlign: TextAlign.end)),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      child: IconButton(tooltip: label, onPressed: onPressed, icon: Icon(icon)),
    );
  }
}

String _label(BuildContext context, String key) {
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  const zhLabels = <String, String>{
    'settings': '设置',
    'download': '下载',
    'downloadUnavailable': '没有可保存的独立字幕源文件',
    'fullscreen': '全屏',
    'translate': '翻译',
    'search': '搜索',
    'searchHint': '搜索当前字幕',
    'previous': '上一个',
    'next': '下一个',
    'lyricStyle': '字幕视图设置',
    'fontSize': '字号',
    'fontWeight': '字重',
    'lineHeight': '行高',
    'reset': '恢复默认',
  };
  const enLabels = <String, String>{
    'settings': 'Settings',
    'download': 'Download',
    'downloadUnavailable': 'No standalone subtitle source is available',
    'fullscreen': 'Fullscreen',
    'translate': 'Translate',
    'search': 'Search',
    'searchHint': 'Search current subtitles',
    'previous': 'Previous',
    'next': 'Next',
    'lyricStyle': 'Lyric view settings',
    'fontSize': 'Size',
    'fontWeight': 'Weight',
    'lineHeight': 'Line height',
    'reset': 'Reset',
  };
  return (zh ? zhLabels : enLabels)[key] ?? key;
}
