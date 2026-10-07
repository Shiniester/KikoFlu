import 'dart:async';

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
import '../utils/ui_tokens.dart';
import 'cached_image_widget.dart';
import 'file_explorer_header.dart';
import 'file_tree_view.dart';
import 'pagination_bar.dart';
import 'sliver_tab_page_view.dart';
import 'tab_page_motion.dart';
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

class _WorkResourceTabsState extends ConsumerState<WorkResourceTabs>
    with TickerProviderStateMixin {
  static const _imagesPerPage = 20;

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
  final _imageAspectRatios = <dynamic, ValueNotifier<double?>>{};
  final _imageFailures = <dynamic, ValueNotifier<bool>>{};
  Map<String, bool> _downloadedFiles = const {};
  List<String>? _reportedNames;
  late AnimationController _pagePosition;
  late TabController _tabs;
  final _tabHeaderKey = GlobalKey();
  int _imagePage = 1;
  bool _reduceMotion = false;
  bool _tabSyncScheduled = false;
  bool _configuringTabs = false;
  int? _motionTarget;

  @override
  void initState() {
    super.initState();
    final tabCount = FileTreeUtils.imageFilesRecursive(widget.fileTree).isEmpty
        ? 2
        : 3;
    _tabs = TabController(
      length: tabCount,
      initialIndex: _selected,
      animationDuration: Duration.zero,
      vsync: this,
    );
    _pagePosition = AnimationController(
      vsync: this,
      lowerBound: 0,
      upperBound: 2,
      value: _selected.toDouble(),
    )..addListener(_handlePagePositionChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion && !_reduceMotion) {
      _pagePosition.stop(canceled: true);
      _pagePosition.value = (_motionTarget ?? _selected).toDouble();
    }
    _reduceMotion = reduceMotion;
  }

  @override
  void dispose() {
    _pagePosition
      ..removeListener(_handlePagePositionChanged)
      ..dispose();
    _tabs.dispose();
    super.dispose();
  }

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
      _imagePage = 1;
      _imageTargets.clear();
      _imageAttempts.clear();
      _imageAspectRatios.clear();
      _imageFailures.clear();
      _motionTarget = null;
      if (_images.isEmpty && _selected == 2) _selected = 1;
      final tabCount = _images.isEmpty ? 2 : 3;
      if (_tabs.length != tabCount) {
        _configuringTabs = true;
        _pagePosition.stop(canceled: true);
        _pagePosition.value = _selected.toDouble();
        _tabs.dispose();
        _tabs = TabController(
          length: tabCount,
          initialIndex: _selected,
          animationDuration: Duration.zero,
          vsync: this,
        );
        _configuringTabs = false;
      }
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
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _reportVisibleNames();
    final s = S.of(context);
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            key: _tabHeaderKey,
            children: [
              TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                onTap: _moveToTab,
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
              if (widget.progressMessage case final message?
                  when message.isNotEmpty)
                FileExplorerProgressBanner(message: message),
            ],
          ),
        ),
        SliverTabPageView(
          position: _pagePosition,
          onDragStart: () {
            _motionTarget = null;
            _pagePosition.stop(canceled: true);
          },
          onDragUpdate: _updatePagePosition,
          onDragEnd: _settlePagePosition,
          onDragCancel: () => _settlePagePosition(0),
          pages: [
            widget.resourceSliver,
            _audioList(context),
            if (_images.isNotEmpty) _imageGrid(context),
          ],
        ),
      ],
    );
  }

  void _moveToTab(int index) {
    syncTabWithPagePosition(_tabs, _pagePosition.value);
    _animateToPage(index.toDouble());
  }

  Future<void> _animateToPage(double target) async {
    final page = target.clamp(0.0, (_tabs.length - 1).toDouble()).toDouble();
    _motionTarget = page.round();
    _pagePosition.stop(canceled: true);
    if (_reduceMotion) {
      _pagePosition.value = page;
      return;
    }
    await _pagePosition.animateTo(
      page,
      duration: tabPageDuration,
      curve: Curves.ease,
    );
  }

  void _updatePagePosition(double pageDelta) {
    _motionTarget = null;
    final maxPage = (_tabs.length - 1).toDouble();
    _pagePosition.value = (_pagePosition.value + pageDelta)
        .clamp(0.0, maxPage)
        .toDouble();
  }

  void _settlePagePosition(double velocity) {
    final page = _pagePosition.value;
    final target = velocity.abs() > 0.5
        ? (velocity > 0 ? page.floor() + 1 : page.ceil() - 1)
        : page.round();
    _animateToPage(target.clamp(0, _tabs.length - 1).toDouble());
  }

  void _handlePagePositionChanged() {
    if (!mounted || _configuringTabs) return;
    final page = _pagePosition.value
        .clamp(0.0, (_tabs.length - 1).toDouble())
        .toDouble();
    if (_tabs.indexIsChanging) {
      _scheduleTabSync();
    } else {
      syncTabWithPagePosition(_tabs, page);
    }
    final selected = page.round();
    if (selected != _selected) setState(() => _selected = selected);
  }

  void _scheduleTabSync() {
    if (_tabSyncScheduled) return;
    _tabSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tabSyncScheduled = false;
      if (!mounted) return;
      if (_tabs.indexIsChanging) {
        _scheduleTabSync();
        return;
      }
      syncTabWithPagePosition(_tabs, _pagePosition.value);
    });
  }

  void _reportVisibleNames() {
    final callback = widget.onVisibleNamesChanged;
    if (callback == null) return;
    final names = switch (_selected) {
      0 => FileTreeUtils.collectNames(
        widget.fileTree,
        expandedFolders: widget.expandedFolders,
      ),
      2 => _currentImagePage.map(FileTreeUtils.titleOf).toSet().toList(),
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

  List<dynamic> get _currentImagePage {
    final start = (_imagePage - 1) * _imagesPerPage;
    return _images.skip(start).take(_imagesPerPage).toList(growable: false);
  }

  Widget _imageGrid(BuildContext context) {
    final pageImages = _currentImagePage;
    return SliverMainAxisGroup(
      slivers: [
        SliverLayoutBuilder(
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
                childCount: pageImages.length,
                itemBuilder: (context, index) {
                  final file = pageImages[index];
                  final imageAspectRatio = _imageAspectRatios.putIfAbsent(
                    file,
                    () => ValueNotifier(null),
                  );
                  final imageFailure = _imageFailures.putIfAbsent(
                    file,
                    () => ValueNotifier(false),
                  );
                  final attempt = _imageAttempts[file] ?? 0;
                  return FutureBuilder<PreviewFileItem?>(
                    key: ObjectKey(file),
                    future: _imageTargets.putIfAbsent(
                      file,
                      () => widget.resolveImage(file),
                    ),
                    builder: (context, snapshot) {
                      final targetFailed =
                          snapshot.hasError ||
                          (snapshot.connectionState == ConnectionState.done &&
                              snapshot.data == null);
                      final target = snapshot.data;
                      return ValueListenableBuilder<bool>(
                        valueListenable: imageFailure,
                        builder: (context, hasImageFailed, _) => ValueListenableBuilder<double?>(
                          valueListenable: imageAspectRatio,
                          builder: (context, knownAspectRatio, _) {
                            final aspectRatio = knownAspectRatio ?? 2 / 3;
                            return Visibility(
                              visible:
                                  knownAspectRatio != null ||
                                  hasImageFailed ||
                                  targetFailed,
                              maintainSize: true,
                              maintainAnimation: true,
                              maintainState: true,
                              child: Card(
                                margin: EdgeInsets.zero,
                                clipBehavior: Clip.antiAlias,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    workCoverCompactRadius,
                                  ),
                                ),
                                child: InkWell(
                                  onTap: () => widget.onImageTap(file),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      WorkCoverClip(
                                        cornerRadius: workCoverCompactRadius,
                                        child: AspectRatio(
                                          aspectRatio: aspectRatio,
                                          child: targetFailed
                                              ? Center(
                                                  child: IconButton(
                                                    tooltip: S
                                                        .of(context)
                                                        .retry,
                                                    icon: const Icon(
                                                      Icons
                                                          .broken_image_outlined,
                                                    ),
                                                    onPressed: () =>
                                                        _retryImage(file),
                                                  ),
                                                )
                                              : target == null
                                              ? const Center(
                                                  child:
                                                      CircularProgressIndicator(),
                                                )
                                              : LayoutBuilder(
                                                  builder:
                                                      (
                                                        context,
                                                        constraints,
                                                      ) => CachedImageWidget(
                                                        key: ValueKey(attempt),
                                                        imageUrl: target.url,
                                                        hash: target.hash,
                                                        cacheWidth:
                                                            (constraints.maxWidth *
                                                                    MediaQuery.devicePixelRatioOf(
                                                                      context,
                                                                    ))
                                                                .ceil(),
                                                        onRetry: () =>
                                                            _retryImage(file),
                                                        onAspectRatio: (ratio) {
                                                          if (mounted &&
                                                              _imageAspectRatios[file] ==
                                                                  imageAspectRatio &&
                                                              imageAspectRatio
                                                                      .value !=
                                                                  ratio) {
                                                            imageAspectRatio
                                                                    .value =
                                                                ratio;
                                                          }
                                                        },
                                                        onImageError: () {
                                                          if (mounted &&
                                                              _imageFailures[file] ==
                                                                  imageFailure) {
                                                            imageFailure.value =
                                                                true;
                                                          }
                                                        },
                                                      ),
                                                ),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: Text(
                                          _displayName(
                                            FileTreeUtils.titleOf(file),
                                          ),
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                                height: 1.1,
                                                fontSize:
                                                    MediaQuery.orientationOf(
                                                          context,
                                                        ) ==
                                                        Orientation.landscape
                                                    ? 14.5
                                                    : 12,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  );
                },
              ),
            );
          },
        ),
        if (_images.length > _imagesPerPage)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: PaginationBar(
                currentPage: _imagePage,
                pageSize: _imagesPerPage,
                totalCount: _images.length,
                hasMore: _imagePage * _imagesPerPage < _images.length,
                isLoading: false,
                onPreviousPage: _imagePage > 1
                    ? () => _changeImagePage(_imagePage - 1)
                    : null,
                onNextPage: _imagePage * _imagesPerPage < _images.length
                    ? () => _changeImagePage(_imagePage + 1)
                    : null,
                onGoToPage: _changeImagePage,
              ),
            ),
          ),
      ],
    );
  }

  void _changeImagePage(int page) {
    final maxPage = (_images.length / _imagesPerPage).ceil();
    if (page < 1 || page > maxPage || page == _imagePage) return;
    setState(() => _imagePage = page);
    unawaited(_scrollToTabHeader());
  }

  Future<void> _scrollToTabHeader() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final headerContext = _tabHeaderKey.currentContext;
    if (headerContext == null || !headerContext.mounted) return;
    await Scrollable.ensureVisible(
      headerContext,
      alignment: 0,
      duration: MediaQuery.disableAnimationsOf(headerContext)
          ? Duration.zero
          : UiMotion.travel,
      curve: UiMotion.curve,
    );
  }

  void _retryImage(dynamic file) => setState(() {
    _imageFailures[file]?.value = false;
    _imageTargets.remove(file);
    _imageAttempts[file] = (_imageAttempts[file] ?? 0) + 1;
  });
}
