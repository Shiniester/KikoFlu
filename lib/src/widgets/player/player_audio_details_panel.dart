import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/work.dart';
import '../../providers/player_work_details_provider.dart';
import '../../services/player_audio_variant_classifier.dart';
import '../circle_chip.dart';
import '../tag_chip.dart';
import '../va_chip.dart';
import 'player_glass_surface.dart';
import 'player_vertical_gestures.dart';

class PlayerAudioDetailsPanel extends ConsumerStatefulWidget {
  const PlayerAudioDetailsPanel({
    super.key,
    this.onOpenWork,
    this.isActive = true,
    this.onDismissPlayer,
    this.dismissDrag,
    this.onShowQueue,
    this.showQueueDrag,
  });

  final ValueChanged<Work>? onOpenWork;
  final bool isActive;
  final VoidCallback? onDismissPlayer;
  final PlayerVerticalDragCallbacks? dismissDrag;
  final VoidCallback? onShowQueue;
  final PlayerVerticalDragCallbacks? showQueueDrag;

  @override
  ConsumerState<PlayerAudioDetailsPanel> createState() =>
      _PlayerAudioDetailsPanelState();
}

class _PlayerAudioDetailsPanelState
    extends ConsumerState<PlayerAudioDetailsPanel> {
  static const _classifier = PlayerAudioVariantClassifier();
  PlayerAudioVariantFilter _filter = const PlayerAudioVariantFilter();
  String? _fileTreeId;
  bool _isQueueing = false;

  @override
  Widget build(BuildContext context) {
    final details = ref.watch(playerWorkDetailsProvider);
    return TickerMode(
      enabled: widget.isActive,
      child: details.when(
        loading: () =>
            _wrapStaticState(const Center(child: CircularProgressIndicator())),
        error: (error, _) =>
            _wrapStaticState(_EmptyDetails(message: error.toString())),
        data: (data) {
          if (data == null) return _wrapStaticState(const _EmptyDetails());
          if (_fileTreeId != data.fileTreeId) {
            _fileTreeId = data.fileTreeId;
            _filter = const PlayerAudioVariantFilter();
          }
          return _buildDetails(context, data);
        },
      ),
    );
  }

  Widget _wrapStaticState(Widget child) {
    return PlayerVerticalSwipeRegion(
      onSwipeDown: widget.onDismissPlayer,
      onSwipeUp: widget.onShowQueue,
      swipeDownDrag: widget.dismissDrag,
      swipeUpDrag: widget.showQueueDrag,
      child: child,
    );
  }

  Widget _buildDetails(BuildContext context, PlayerWorkDetailsData details) {
    final work = details.work;
    final colors = Theme.of(context).colorScheme;
    final variants = _classifier.applyFilter(details.variants, _filter);
    final hasCircle = work.name?.trim().isNotEmpty == true;
    final hasRelease = work.release?.trim().isNotEmpty == true;
    final hasVoiceActors = work.vas?.isNotEmpty == true;
    final hasEditions = work.otherLanguageEditions?.isNotEmpty == true;
    final hasTags = work.tags?.isNotEmpty == true;

    return RepaintBoundary(
      key: const ValueKey('player-audio-details-panel'),
      child: PlayerScrollEdgeActions(
        onPullDownAtTop: widget.onDismissPlayer,
        onPushUpAtBottom: widget.onShowQueue,
        pullDownDrag: widget.dismissDrag,
        pushUpDrag: widget.showQueueDrag,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
              sliver: SliverList.list(
                children: [
                  _InfoCard(
                    key: const ValueKey('player-detail-album'),
                    title: _label(context, 'album'),
                    onTap: widget.onOpenWork == null
                        ? null
                        : () => widget.onOpenWork!(work),
                    trailing: widget.onOpenWork == null
                        ? null
                        : const Icon(Icons.chevron_right, size: 18),
                    child: Text(
                      work.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        height: 1.18,
                      ),
                    ),
                  ),
                  if (hasCircle || hasRelease) ...[
                    const SizedBox(height: 8),
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (hasCircle)
                            Expanded(
                              child: _InfoCard(
                                key: const ValueKey('player-detail-circle'),
                                title: _label(context, 'circle'),
                                child: Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: CircleChip(
                                    circleId: work.circleId ?? 0,
                                    circleName: work.name!.trim(),
                                    compact: true,
                                    fontSize: 11.5,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 3,
                                    ),
                                    borderRadius: 6,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          if (hasCircle && hasRelease) const SizedBox(width: 8),
                          if (hasRelease)
                            Expanded(
                              child: _InfoCard(
                                key: const ValueKey('player-detail-release'),
                                title: _label(context, 'release'),
                                child: Text(
                                  work.release!.trim().split('T').first,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (hasVoiceActors) ...[
                    const SizedBox(height: 8),
                    _InfoCard(
                      key: const ValueKey('player-detail-voice-actors'),
                      title: _label(context, 'voiceActors'),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final va in work.vas!)
                            VaChip(
                              va: va,
                              compact: true,
                              fontSize: 11.5,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              borderRadius: 6,
                              fontWeight: FontWeight.w600,
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  _InfoCard(
                    key: const ValueKey('player-detail-audio-files'),
                    title: _label(context, 'audioFiles'),
                    borderRadius: variants.isEmpty
                        ? BorderRadius.circular(12)
                        : const BorderRadius.vertical(top: Radius.circular(12)),
                    trailing: IconButton.filledTonal(
                      key: const ValueKey('player-audio-filter-button'),
                      onPressed: details.variants.isEmpty
                          ? null
                          : () => _showFilterSheet(context),
                      icon: const Icon(Icons.tune, size: 18),
                      tooltip: _label(context, 'filter'),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: details.variants.isEmpty
                        ? Text(
                            _label(context, 'noFiles'),
                            style: TextStyle(color: colors.onSurfaceVariant),
                          )
                        : Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              variants.isEmpty
                                  ? _label(context, 'noMatch')
                                  : _filter.showAll
                                  ? _labelCount(context, variants.length)
                                  : _labelBestCount(context, variants.length),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            if (variants.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.zero,
                sliver: SliverList.builder(
                  itemCount: variants.length,
                  itemBuilder: (context, index) {
                    final variant = variants[index];
                    final isLast = index == variants.length - 1;
                    return PlayerGlassSurface(
                      borderRadius: isLast
                          ? const BorderRadius.vertical(
                              bottom: Radius.circular(12),
                            )
                          : BorderRadius.zero,
                      borderColor: Colors.transparent,
                      child: _AudioVariantTile(
                        variant: variant,
                        enabled: !_isQueueing,
                        onTap: () => _enqueueNext(details, variant),
                      ),
                    );
                  },
                ),
              )
            else
              const SliverToBoxAdapter(child: SizedBox.shrink()),
            if (hasEditions || hasTags)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
                sliver: SliverList.list(
                  children: [
                    if (hasEditions)
                      _InfoCard(
                        key: const ValueKey('player-detail-other-editions'),
                        title: _label(context, 'versions'),
                        child: Column(
                          children: [
                            for (final edition in work.otherLanguageEditions!)
                              ListTile(
                                dense: true,
                                visualDensity: const VisualDensity(
                                  horizontal: -4,
                                  vertical: -4,
                                ),
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  edition.lang,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.1,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      edition.sourceId,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right, size: 18),
                                  ],
                                ),
                                onTap: widget.onOpenWork == null
                                    ? null
                                    : () => widget.onOpenWork!(
                                        Work(
                                          id: edition.id,
                                          title: edition.title,
                                          sourceId: edition.sourceId,
                                        ),
                                      ),
                              ),
                          ],
                        ),
                      ),
                    if (hasEditions && hasTags) const SizedBox(height: 8),
                    if (hasTags)
                      _InfoCard(
                        key: const ValueKey('player-detail-tags'),
                        title: _label(context, 'tags'),
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 3,
                          children: [
                            for (final tag in work.tags!)
                              TagChip(
                                tag: tag,
                                compact: true,
                                fontSize: 11,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                borderRadius: 6,
                                fontWeight: FontWeight.w500,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              )
            else
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  Future<void> _enqueueNext(
    PlayerWorkDetailsData details,
    PlayerAudioVariant variant,
  ) async {
    if (_isQueueing) return;
    setState(() => _isQueueing = true);
    final result = await ref
        .read(playerAudioVariantQueueControllerProvider)
        .enqueueNext(details: details, variant: variant);
    if (mounted) {
      setState(() => _isQueueing = false);
      final message = switch (result.status) {
        PlayerEnqueueVariantStatus.queued => _label(context, 'queuedNext'),
        PlayerEnqueueVariantStatus.currentTrack => _label(
          context,
          'alreadyPlaying',
        ),
        PlayerEnqueueVariantStatus.unavailable => _label(
          context,
          'unavailable',
        ),
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
    }
  }

  Future<void> _showFilterSheet(BuildContext context) async {
    final result = await showModalBottomSheet<PlayerAudioVariantFilter>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (sheetContext) => PlayerBackdropGroup(
        child: PlayerTransientGlassSurface(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          child: _AudioVariantFilterSheet(initial: _filter),
        ),
      ),
    );
    if (result != null && mounted) setState(() => _filter = result);
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final VoidCallback? onTap;
  final BorderRadiusGeometry borderRadius;

  @override
  Widget build(BuildContext context) {
    return PlayerGlassSurface(
      borderRadius: borderRadius,
      borderColor: Colors.transparent,
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      onTap: onTap,
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontSize: 13, height: 1.16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 6),
            child,
          ],
        ),
      ),
    );
  }
}

class _AudioVariantTile extends StatelessWidget {
  const _AudioVariantTile({
    required this.variant,
    required this.enabled,
    required this.onTap,
  });

  final PlayerAudioVariant variant;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    return ListTile(
      key: ValueKey('player-audio-variant-${variant.fullPath}'),
      dense: true,
      visualDensity: const VisualDensity(horizontal: -2, vertical: -4),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      enabled: enabled,
      onTap: onTap,
      title: Text(
        variant.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 12.5,
          height: 1.12,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        _variantSummary(context, variant),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: secondary, fontSize: 10.5, height: 1.15),
      ),
      trailing: Tooltip(
        message: _label(context, 'playNext'),
        child: const Icon(Icons.playlist_add, size: 18),
      ),
    );
  }
}

class _AudioVariantFilterSheet extends StatefulWidget {
  const _AudioVariantFilterSheet({required this.initial});

  final PlayerAudioVariantFilter initial;

  @override
  State<_AudioVariantFilterSheet> createState() =>
      _AudioVariantFilterSheetState();
}

class _AudioVariantFilterSheetState extends State<_AudioVariantFilterSheet> {
  late PlayerAudioVariantFilter _filter = widget.initial;
  late final TextEditingController _keywordController = TextEditingController(
    text: widget.initial.keyword,
  );

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          10,
          16,
          12 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _label(context, 'filterAudio'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontSize: 18,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _keywordController,
                decoration: InputDecoration(
                  labelText: _label(context, 'keyword'),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _chips<PlayerSubtitleLanguage>(
                context,
                title: _label(context, 'subtitleLanguage'),
                values: PlayerSubtitleLanguage.values.where(
                  (value) => value != PlayerSubtitleLanguage.unknown,
                ),
                selected: _filter.subtitleLanguages,
                label: (value) => _subtitleLabel(context, value),
                onChanged: (values) => setState(
                  () => _filter = _filter.copyWith(subtitleLanguages: values),
                ),
              ),
              _chips<PlayerAudioFormat>(
                context,
                title: _label(context, 'format'),
                values: PlayerAudioFormat.values,
                selected: _filter.formats,
                label: (value) => value.name.toUpperCase(),
                onChanged: (values) =>
                    setState(() => _filter = _filter.copyWith(formats: values)),
              ),
              _chips<PlayerBinaryTrait>(
                context,
                title: _label(context, 'effects'),
                values: const [
                  PlayerBinaryTrait.present,
                  PlayerBinaryTrait.absent,
                ],
                selected: _filter.seValues,
                label: (value) => _traitLabel(context, value),
                onChanged: (values) => setState(
                  () => _filter = _filter.copyWith(seValues: values),
                ),
              ),
              _chips<PlayerBinaryTrait>(
                context,
                title: _label(context, 'ejaculation'),
                values: const [
                  PlayerBinaryTrait.present,
                  PlayerBinaryTrait.absent,
                ],
                selected: _filter.ejaculationValues,
                label: (value) => _traitLabel(context, value),
                onChanged: (values) => setState(
                  () => _filter = _filter.copyWith(ejaculationValues: values),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                visualDensity: const VisualDensity(vertical: -3),
                value: _filter.includeUnknown,
                title: Text(
                  _label(context, 'includeUnknown'),
                  style: const TextStyle(fontSize: 12.5, height: 1.1),
                ),
                onChanged: (value) => setState(
                  () => _filter = _filter.copyWith(includeUnknown: value),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                visualDensity: const VisualDensity(vertical: -3),
                value: _filter.showAll,
                title: Text(
                  _label(context, 'showAll'),
                  style: const TextStyle(fontSize: 12.5, height: 1.1),
                ),
                onChanged: (value) =>
                    setState(() => _filter = _filter.copyWith(showAll: value)),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  TextButton(
                    onPressed: () => setState(() {
                      _filter = const PlayerAudioVariantFilter();
                      _keywordController.clear();
                    }),
                    child: Text(_label(context, 'reset')),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(_filter.copyWith(keyword: _keywordController.text)),
                    child: Text(_label(context, 'apply')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chips<T>(
    BuildContext context, {
    required String title,
    required Iterable<T> values,
    required Set<T> selected,
    required String Function(T value) label,
    required ValueChanged<Set<T>> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontSize: 12,
              height: 1.08,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final value in values)
                FilterChip(
                  visualDensity: const VisualDensity(
                    horizontal: -2,
                    vertical: -2,
                  ),
                  label: Text(
                    label(value),
                    style: const TextStyle(fontSize: 12, height: 1.05),
                  ),
                  selected: selected.contains(value),
                  onSelected: (enabled) {
                    final next = Set<T>.of(selected);
                    enabled ? next.add(value) : next.remove(value);
                    onChanged(next);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyDetails extends StatelessWidget {
  const _EmptyDetails({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message ?? _label(context, 'noDetails'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

String _variantSummary(BuildContext context, PlayerAudioVariant variant) {
  return <String>[
    variant.format.name.toUpperCase(),
    _subtitleLabel(context, variant.subtitleLanguage),
    '${_label(context, 'effects')}: ${_traitLabel(context, variant.se)}',
    '${_label(context, 'ejaculation')}: ${_traitLabel(context, variant.ejaculation)}',
  ].join(' · ');
}

String _subtitleLabel(BuildContext context, PlayerSubtitleLanguage value) {
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  return switch (value) {
    PlayerSubtitleLanguage.simplifiedChinese =>
      zh ? '简体中文' : 'Simplified Chinese',
    PlayerSubtitleLanguage.traditionalChinese =>
      zh ? '繁体中文' : 'Traditional Chinese',
    PlayerSubtitleLanguage.other => zh ? '其他语言' : 'Other language',
    PlayerSubtitleLanguage.none => zh ? '无字幕' : 'No subtitle',
    PlayerSubtitleLanguage.unknown => zh ? '未知' : 'Unknown',
  };
}

String _traitLabel(BuildContext context, PlayerBinaryTrait value) {
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  return switch (value) {
    PlayerBinaryTrait.present => zh ? '有' : 'Yes',
    PlayerBinaryTrait.absent => zh ? '无' : 'No',
    PlayerBinaryTrait.unknown => zh ? '未知' : 'Unknown',
  };
}

String _labelCount(BuildContext context, int count) {
  return Localizations.localeOf(context).languageCode == 'zh'
      ? '共 $count 个音频文件'
      : '$count audio files';
}

String _labelBestCount(BuildContext context, int count) {
  return Localizations.localeOf(context).languageCode == 'zh'
      ? '最佳可用组合 · $count 个文件'
      : 'Best available combination · $count files';
}

String _label(BuildContext context, String key) {
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  const zhLabels = <String, String>{
    'album': '专辑标题',
    'circle': '社团',
    'voiceActors': '声优',
    'tags': '标签',
    'release': '发售日期',
    'versions': '其他版本',
    'audioFiles': '音频文件',
    'filter': '筛选',
    'filterAudio': '筛选音频文件',
    'noFiles': '没有可用的音频文件',
    'noMatch': '没有符合筛选条件的文件',
    'noDetails': '暂无可用的作品信息',
    'keyword': '文件或目录关键词',
    'subtitleLanguage': '字幕语言',
    'format': '音频格式',
    'effects': '效果音',
    'ejaculation': '射精音',
    'includeUnknown': '包含无法识别的项目',
    'showAll': '显示全部组合',
    'reset': '重置',
    'apply': '应用',
    'playNext': '下一首播放',
    'queuedNext': '已设为下一首播放',
    'alreadyPlaying': '该音频正在播放',
    'unavailable': '当前无法加入播放队列',
  };
  const enLabels = <String, String>{
    'album': 'Album',
    'circle': 'Circle',
    'voiceActors': 'Voice actors',
    'tags': 'Tags',
    'release': 'Release date',
    'versions': 'Other editions',
    'audioFiles': 'Audio files',
    'filter': 'Filter',
    'filterAudio': 'Filter audio files',
    'noFiles': 'No audio files available',
    'noMatch': 'No files match these filters',
    'noDetails': 'No work details are available',
    'keyword': 'File or folder keyword',
    'subtitleLanguage': 'Subtitle language',
    'format': 'Audio format',
    'effects': 'Sound effects',
    'ejaculation': 'Ejaculation sound',
    'includeUnknown': 'Include unknown items',
    'showAll': 'Show every combination',
    'reset': 'Reset',
    'apply': 'Apply',
    'playNext': 'Play next',
    'queuedNext': 'Queued to play next',
    'alreadyPlaying': 'This audio is already playing',
    'unavailable': 'Unable to add this file to the queue',
  };
  return (zh ? zhLabels : enLabels)[key] ?? key;
}
