import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../l10n/app_localizations.dart';
import '../providers/player_subtitle_candidates_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/work_card_display_provider.dart';
import '../providers/works_provider.dart' show LayoutType;
import '../services/file_preview_resolver.dart';
import '../services/player_audio_variant_classifier.dart';
import '../utils/collection_grid_layout.dart';
import '../utils/file_tree_utils.dart';
import '../utils/file_icon_utils.dart';
import '../utils/snackbar_util.dart';
import 'cached_image_widget.dart';
import 'file_explorer_header.dart';
import 'file_tree_view.dart';
import 'work_detail/work_cover_frame.dart';

typedef ResourceAudioAction =
    void Function(dynamic file, String parentPath, List<dynamic> audioFiles);
typedef ResourceAudioLongPress =
    void Function(
      dynamic file,
      String title,
      String parentPath,
      List<dynamic> audioFiles,
    );

class WorkResourceTabs extends ConsumerStatefulWidget {
  const WorkResourceTabs({
    super.key,
    required this.workId,
    required this.fileTree,
    required this.audioVariants,
    required this.resourceSliver,
    required this.resourceTitle,
    required this.onPlayAudio,
    required this.onFileTap,
    required this.resolveImage,
    required this.onImageTap,
    this.progressMessage,
    this.displayNameFor,
    this.metadataBuilder,
    this.audioTrailingBuilder,
    this.onAudioLongPress,
    this.expandedFolders = const {},
    this.onVisibleNamesChanged,
    this.downloadedFiles = const {},
  });

  final int workId;
  final List<dynamic> fileTree;
  final List<PlayerAudioVariant> audioVariants;
  final Widget resourceSliver;
  final String resourceTitle;
  final ResourceAudioAction onPlayAudio;
  final FileTreeItemTap onFileTap;
  final Future<PreviewFileItem?> Function(dynamic) resolveImage;
  final ValueChanged<dynamic> onImageTap;
  final String? progressMessage;
  final FileTreeDisplayNameBuilder? displayNameFor;
  final FileTreeMetadataBuilder? metadataBuilder;
  final FileTreeTrailingBuilder? audioTrailingBuilder;
  final ResourceAudioLongPress? onAudioLongPress;
  final Set<String> expandedFolders;
  final ValueChanged<List<String>>? onVisibleNamesChanged;
  final Map<String, bool> downloadedFiles;

  @override
  ConsumerState<WorkResourceTabs> createState() => _WorkResourceTabsState();
}

class _WorkResourceTabsState extends ConsumerState<WorkResourceTabs> {
  int _selected = 1;
  List<dynamic>? _tree;
  List<PlayerAudioVariant>? _variants;
  AudioFormatPreference? _preference;
  List<dynamic> _images = const [];
  List<PlayerAudioVariant> _audio = const [];
  List<dynamic> _queue = const [];
  List<PlayerSubtitleCandidate?> _subtitles = const [];
  final _imageTargets = <dynamic, Future<PreviewFileItem?>>{};
  final _imageAttempts = <dynamic, int>{};
  Map<String, bool> _downloadedFiles = const {};
  List<String>? _reportedNames;

  void _updateResources(AudioFormatPreference preference) {
    for (final image in _images) {
      final hash = FileTreeUtils.property(image, 'hash')?.toString();
      if (_downloadedFiles[hash] != widget.downloadedFiles[hash]) {
        _imageTargets.remove(image);
        _imageAttempts[image] = (_imageAttempts[image] ?? 0) + 1;
      }
    }
    _downloadedFiles = Map.of(widget.downloadedFiles);
    final treeChanged = !identical(_tree, widget.fileTree);
    if (!treeChanged &&
        identical(_variants, widget.audioVariants) &&
        identical(_preference, preference)) {
      return;
    }
    if (treeChanged) {
      _images = FileTreeUtils.imageFilesRecursive(widget.fileTree);
      _imageTargets.clear();
      _imageAttempts.clear();
      if (_images.isEmpty && _selected == 2) _selected = 1;
    }
    _tree = widget.fileTree;
    _variants = widget.audioVariants;
    _preference = preference;
    _audio = const PlayerAudioVariantClassifier().selectBest(
      widget.audioVariants,
      preference: preference,
    );
    _queue = _audio.map((variant) => variant.source).toList(growable: false);
    const repository = PlayerSubtitleCandidateRepository();
    // ponytail: scans subtitles per selected track; index names if large catalogs dominate.
    _subtitles = [
      for (final variant in _audio)
        repository
            .collectWorkCandidates(
              fileTree: widget.fileTree,
              audioTitle: variant.title,
              audioHash: FileTreeUtils.property(
                variant.source,
                'hash',
              )?.toString(),
              audioParentPath: variant.parentPath,
              workId: widget.workId,
            )
            .where((candidate) => candidate.matchesCurrentAudio)
            .firstOrNull,
    ];
  }

  @override
  Widget build(BuildContext context) {
    _updateResources(ref.watch(audioFormatPreferenceProvider));
    _reportVisibleNames();
    final s = S.of(context);
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            children: [
              DefaultTabController(
                key: ValueKey(_images.isNotEmpty),
                length: _images.isEmpty ? 2 : 3,
                initialIndex: _selected,
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  onTap: (index) => setState(() => _selected = index),
                  tabs: [
                    Tab(
                      key: const ValueKey('work-resource-files-tab'),
                      text: widget.resourceTitle,
                    ),
                    Tab(
                      key: const ValueKey('work-resource-audio-tab'),
                      text: s.workResourceAudio,
                    ),
                    if (_images.isNotEmpty)
                      Tab(
                        key: const ValueKey('work-resource-images-tab'),
                        text: s.workResourceImages,
                      ),
                  ],
                ),
              ),
              if (widget.progressMessage case final message?
                  when message.isNotEmpty)
                FileExplorerProgressBanner(message: message),
            ],
          ),
        ),
        switch (_selected) {
          0 => widget.resourceSliver,
          2 => _imageGrid(context),
          _ => _audioList(context),
        },
      ],
    );
  }

  void _reportVisibleNames() {
    final callback = widget.onVisibleNamesChanged;
    if (callback == null) return;
    final names = switch (_selected) {
      0 => FileTreeUtils.collectNames(
        widget.fileTree,
        expandedFolders: widget.expandedFolders,
      ),
      2 => _images.map(FileTreeUtils.titleOf).toSet().toList(),
      _ => _audio.map((variant) => variant.title).toSet().toList(),
    };
    if (listEquals(_reportedNames, names)) return;
    _reportedNames = names;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && listEquals(_reportedNames, names)) callback(names);
    });
  }

  String _displayName(String title) =>
      widget.displayNameFor?.call(title) ?? title;

  FileTreeEntry _entry(dynamic source, String parent, String title) =>
      FileTreeEntry(
        item: source,
        parentPath: parent,
        itemPath: FileTreeUtils.itemPath(parent, source),
        originalTitle: title,
        displayTitle: _displayName(title),
        isFolder: false,
        isExpanded: false,
        children: null,
        level: 0,
      );

  Widget _audioList(BuildContext context) {
    if (_audio.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(S.of(context).noPlayableAudioFiles),
        ),
      );
    }
    return SliverList.builder(
      itemCount: _audio.length,
      itemBuilder: (context, index) {
        final variant = _audio[index];
        final entry = _entry(variant.source, variant.parentPath, variant.title);
        final subtitle = _subtitles[index];
        final hash = FileTreeUtils.property(variant.source, 'hash')?.toString();
        final metadata = widget.metadataBuilder?.call(context, entry);
        final actions = widget.audioTrailingBuilder?.call(context, entry);
        final audioColor = FileIconUtils.getFileIconColorByName(variant.title);
        return ListTile(
          key: ValueKey('work-audio-${variant.fullPath}'),
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            widget.downloadedFiles[hash] == true
                ? Icons.download_done
                : Icons.audiotrack,
            color: audioColor,
          ),
          title: Text(entry.displayTitle, style: const TextStyle(fontSize: 14)),
          subtitle: variant.parentPath.isEmpty
              ? null
              : Text(variant.parentPath, style: const TextStyle(fontSize: 12)),
          onTap: () =>
              widget.onPlayAudio(variant.source, variant.parentPath, _queue),
          onLongPress: widget.onAudioLongPress == null
              ? () => _copyName(entry.displayTitle)
              : () => widget.onAudioLongPress!(
                  variant.source,
                  entry.displayTitle,
                  variant.parentPath,
                  _queue,
                ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (metadata != null) metadata,
              IconButton(
                tooltip: entry.displayTitle,
                icon: Icon(Icons.play_arrow, color: audioColor),
                iconSize: 20,
                onPressed: () => widget.onPlayAudio(
                  variant.source,
                  variant.parentPath,
                  _queue,
                ),
              ),
              if (subtitle != null)
                IconButton(
                  key: ValueKey('work-audio-subtitle-${variant.fullPath}'),
                  tooltip: S.of(context).preview,
                  icon: const Icon(Icons.visibility),
                  color: Colors.blue,
                  iconSize: 20,
                  onPressed: () => widget.onFileTap(
                    subtitle.source,
                    _displayName(subtitle.title),
                    _subtitleParent(subtitle),
                  ),
                ),
              if (actions != null) actions,
            ],
          ),
        );
      },
    );
  }

  String _subtitleParent(PlayerSubtitleCandidate subtitle) {
    final separator = subtitle.pathLabel.lastIndexOf('/');
    return separator < 0 ? '' : subtitle.pathLabel.substring(0, separator);
  }

  Future<void> _copyName(String title) async {
    await Clipboard.setData(ClipboardData(text: title));
    if (mounted) {
      SnackBarUtil.showSuccess(context, S.of(context).copiedName(title));
    }
  }

  Widget _imageGrid(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final metrics = resolveCollectionGridMetrics(
        context,
        layoutType: LayoutType.bigGrid,
        cardSize: WorkCardSize.normal,
        availableWidth: constraints.crossAxisExtent,
        padding: const EdgeInsets.only(top: 8),
      );
      return SliverPadding(
        padding: metrics.padding,
        sliver: SliverMasonryGrid.count(
          crossAxisCount: metrics.crossAxisCount,
          crossAxisSpacing: metrics.spacing,
          mainAxisSpacing: metrics.spacing,
          childCount: _images.length,
          itemBuilder: (context, index) {
            final file = _images[index];
            return Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(workCoverCompactRadius),
              ),
              child: InkWell(
                onTap: () => widget.onImageTap(file),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    WorkCoverClip(
                      cornerRadius: workCoverCompactRadius,
                      child: FutureBuilder<PreviewFileItem?>(
                        future: _imageTargets.putIfAbsent(
                          file,
                          () => widget.resolveImage(file),
                        ),
                        builder: (context, snapshot) {
                          if (snapshot.hasError ||
                              (snapshot.connectionState ==
                                      ConnectionState.done &&
                                  snapshot.data == null)) {
                            return SizedBox(
                              height: 100,
                              child: Center(
                                child: IconButton(
                                  tooltip: S.of(context).retry,
                                  icon: const Icon(Icons.broken_image_outlined),
                                  onPressed: () => _retryImage(file),
                                ),
                              ),
                            );
                          }
                          final target = snapshot.data;
                          if (target == null) {
                            return const SizedBox(
                              height: 100,
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          return LayoutBuilder(
                            builder: (context, constraints) =>
                                CachedImageWidget(
                                  key: ValueKey(_imageAttempts[file] ?? 0),
                                  imageUrl: target.url,
                                  hash: target.hash,
                                  cacheWidth:
                                      (constraints.maxWidth *
                                              MediaQuery.devicePixelRatioOf(
                                                context,
                                              ))
                                          .ceil(),
                                  onRetry: () => _retryImage(file),
                                ),
                          );
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        _displayName(FileTreeUtils.titleOf(file)),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          height: 1.1,
                          fontSize:
                              MediaQuery.orientationOf(context) ==
                                  Orientation.landscape
                              ? 14.5
                              : 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    },
  );

  void _retryImage(dynamic file) => setState(() {
    _imageTargets.remove(file);
    _imageAttempts[file] = (_imageAttempts[file] ?? 0) + 1;
  });
}
