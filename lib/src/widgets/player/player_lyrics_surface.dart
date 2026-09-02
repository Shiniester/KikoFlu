import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/lyric_provider.dart';
import '../../providers/player_lyric_style_provider.dart';
import 'lyric_display_widget.dart';
import 'player_glass_surface.dart';

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
    this.onDismissPlayer,
    this.onShowQueue,
    this.actionWidth,
  });

  final bool isWide;
  final Duration? seekingPosition;
  final VoidCallback onFullscreen;
  final Widget translateButton;
  final bool isActive;
  final VoidCallback? onDownload;
  final VoidCallback? onLongPress;
  final VoidCallback? onDismissPlayer;
  final VoidCallback? onShowQueue;
  final double? actionWidth;

  @override
  ConsumerState<PlayerLyricsSurface> createState() =>
      _PlayerLyricsSurfaceState();
}

class _PlayerLyricsSurfaceState extends ConsumerState<PlayerLyricsSurface> {
  final FullLyricDisplayController _displayController =
      FullLyricDisplayController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _searching = false;
  List<int> _matches = const [];
  int _matchCursor = -1;

  @override
  void dispose() {
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
    final actionHeight = _searching ? 126.0 : 82.0;
    final selectedIndex = _matchCursor >= 0 && _matchCursor < _matches.length
        ? _matches[_matchCursor]
        : null;
    return RepaintBoundary(
      key: ValueKey('player-lyrics-surface-${widget.isWide}'),
      child: Stack(
        children: [
          ShaderMask(
            key: const ValueKey('lyric-edge-fade-mask'),
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.white,
                Colors.white,
                Colors.transparent,
              ],
              stops: [0, 0.09, 0.72, 0.88],
            ).createShader(bounds),
            child: FullLyricDisplay(
              controller: _displayController,
              seekingPosition: widget.seekingPosition,
              isPortrait: !widget.isWide,
              onLongPress: widget.onLongPress,
              suspendAutoScroll: _searching || !widget.isActive,
              searchQuery: _searchController.text,
              selectedSearchIndex: selectedIndex,
              topPadding: 86,
              bottomPadding: actionHeight + (widget.isWide ? 136 : 164),
              snapToCurrentOnFirstLayout: true,
              onDismissPlayer: widget.onDismissPlayer,
              onShowQueue: widget.onShowQueue,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 14,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_searching) _buildSearchBar(context, state),
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
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context, LyricState state) {
    final countLabel = _matches.isEmpty
        ? '0/0'
        : '${_matchCursor + 1}/${_matches.length}';
    return SizedBox(
      width: widget.actionWidth ?? double.infinity,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: PlayerGlassSurface(
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
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: _label(context, 'searchHint'),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onChanged: (_) => _updateMatches(state),
                ),
              ),
              Text(countLabel, style: Theme.of(context).textTheme.labelMedium),
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
    );
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _searchController.clear();
        _matches = const [];
        _matchCursor = -1;
      }
    });
    if (_searching) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocusNode.requestFocus();
      });
    } else {
      _searchFocusNode.unfocus();
    }
  }

  void _updateMatches(LyricState state) {
    final query = _searchController.text.trim().toLowerCase();
    final matches = <int>[];
    if (query.isNotEmpty) {
      final lyrics = state.displayLyrics;
      for (var index = 0; index < lyrics.length; index++) {
        if (lyrics[index].text.toLowerCase().contains(query)) {
          matches.add(index);
        }
      }
    }
    setState(() {
      _matches = matches;
      _matchCursor = matches.isEmpty ? -1 : 0;
    });
    if (matches.isNotEmpty) _displayController.scrollToIndex(matches.first);
  }

  void _moveMatch(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _matchCursor = (_matchCursor + delta) % _matches.length;
      if (_matchCursor < 0) _matchCursor += _matches.length;
    });
    _displayController.scrollToIndex(_matches[_matchCursor]);
  }

  Future<void> _showSettings(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (_) => const PlayerBackdropGroup(
        child: PlayerGlassSurface(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          grouped: false,
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
