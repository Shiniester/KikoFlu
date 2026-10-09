import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../l10n/app_localizations.dart';
import '../providers/player_subtitle_candidates_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/work_card_display_provider.dart';
import '../providers/work_detail_display_provider.dart';
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
import 'image_prefetch_queue.dart';
import 'pagination_bar.dart';
import 'sliver_masonry_grid_tail.dart';
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

enum WorkResourceTab { resources, audio, images, recommendations }

class WorkResourceTabs extends ConsumerStatefulWidget {
  const WorkResourceTabs({
    super.key,
    required this.workId,
    required this.fileTree,
    required this.audioVariants,
    required this.resourceSliver,
    required this.resourceTitle,
    this.recommendationBuilder,
    this.initialTab = WorkResourceTab.audio,
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
  final WidgetBuilder? recommendationBuilder;
  final WorkResourceTab initialTab;
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
  final _resolvedImageTargets = <dynamic, PreviewFileItem>{};
  final _imageTargetSignals =
      <dynamic, ValueNotifier<Future<PreviewFileItem?>?>>{};
  final _imageAttempts = <dynamic, int>{};
  final _imageAspectRatios = <dynamic, ValueNotifier<double?>>{};
  final _imageFailures = <dynamic, ValueNotifier<bool>>{};
  final _imageItemKeys = <dynamic, GlobalKey>{};
  final _imagePageGatePassed = ValueNotifier(false);
  late final _imagePrefetchQueue = ImagePrefetchQueue<dynamic>(
    keyOf: (file) => (file, _imageAttempts[file] ?? 0, _imageCacheWidth),
    prepare: _prepareImage,
  );
  ScrollPosition? _verticalPosition;
  final _tabScrollOffsets = <WorkResourceTab, double>{};
  int? _imageCacheWidth;
  bool _imageInspectionScheduled = false;
  Map<String, bool> _downloadedFiles = const {};
  List<String>? _reportedNames;
  late AnimationController _pagePosition;
  late TabController _tabs;
  final _resourceGroupKey = GlobalKey();
  int _imagePage = 1;
  bool _reduceMotion = false;
  bool _tabSyncScheduled = false;
  bool _configuringTabs = false;
  bool _dragScrollPending = false;
  double? _unpinnedSwipeOffset;
  bool _fillResourceViewport = false;
  bool _recommendationVisited = false;
  int? _motionTarget;
  int _tabMotionGeneration = 0;
  WorkResourceTab? _transitionSource;
  late List<WorkResourceTab> _pageKinds;
  late List<WorkResourceTab> _tabKinds;

  @override
  void initState() {
    super.initState();
    _images = FileTreeUtils.imageFilesRecursive(widget.fileTree);
    _pageKinds = _buildPageKinds();
    _tabKinds = _visibleTabKinds(
      widget.recommendationBuilder != null &&
          ref.read(workDetailDisplayProvider).showRecommendations,
    );
    _selected = _tabKinds.indexOf(widget.initialTab);
    if (_selected < 0) _selected = _tabKinds.indexOf(WorkResourceTab.audio);
    if (_selected < 0) _selected = 0;
    _recommendationVisited =
        _tabKinds[_selected] == WorkResourceTab.recommendations;
    _tabs = TabController(
      length: _tabKinds.length,
      initialIndex: _selected,
      animationDuration: Duration.zero,
      vsync: this,
    );
    _pagePosition = AnimationController(
      vsync: this,
      lowerBound: 0,
      upperBound: 3,
      value: _selected.toDouble(),
    )..addListener(_handlePagePositionChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final verticalPosition = Scrollable.maybeOf(
      context,
      axis: Axis.vertical,
    )?.position;
    if (_verticalPosition != verticalPosition) {
      _verticalPosition?.removeListener(_scheduleImageInspection);
      _verticalPosition = verticalPosition;
      _verticalPosition?.addListener(_scheduleImageInspection);
    }
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion && !_reduceMotion) {
      _pagePosition.stop(canceled: true);
      _pagePosition.value = (_motionTarget ?? _selected).toDouble();
    }
    _reduceMotion = reduceMotion;
  }

  @override
  void dispose() {
    _verticalPosition?.removeListener(_scheduleImageInspection);
    _imagePrefetchQueue.dispose();
    for (final signal in _imageTargetSignals.values) {
      signal.dispose();
    }
    _imagePageGatePassed.dispose();
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
        _resolvedImageTargets.remove(image);
        _imageTargetSignals[image]?.value = null;
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
      _imagePrefetchQueue.update(
        items: const [],
        visible: const [],
        active: false,
      );
      _images = FileTreeUtils.imageFilesRecursive(widget.fileTree);
      _imagePage = 1;
      _imageTargets.clear();
      _resolvedImageTargets.clear();
      for (final signal in _imageTargetSignals.values) {
        signal.dispose();
      }
      _imageTargetSignals.clear();
      _imageAttempts.clear();
      _imageAspectRatios.clear();
      _imageFailures.clear();
      _imageItemKeys.clear();
      _imagePageGatePassed.value = false;
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
    final showRecommendations =
        widget.recommendationBuilder != null &&
        ref.watch(
          workDetailDisplayProvider.select(
            (settings) => settings.showRecommendations,
          ),
        );
    _syncTabs(showRecommendations: showRecommendations);
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _reportVisibleNames();
    final s = S.of(context);
    final tabBar = TabBar(
      controller: _tabs,
      isScrollable: false,
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      onTap: _moveToTab,
      tabs: [
        for (final tab in _tabKinds)
          switch (tab) {
            WorkResourceTab.resources => Tab(
              key: const ValueKey('work-resource-files-tab'),
              text: widget.resourceTitle,
            ),
            WorkResourceTab.audio => Tab(
              key: const ValueKey('work-resource-audio-tab'),
              text: s.workResourceAudio,
            ),
            WorkResourceTab.images => Tab(
              key: const ValueKey('work-resource-images-tab'),
              text: s.workResourceImages,
            ),
            WorkResourceTab.recommendations => Tab(
              key: const ValueKey('work-resource-recommendations-tab'),
              child: Text(
                s.relatedRecommendations,
                maxLines: 2,
                textAlign: TextAlign.center,
              ),
            ),
          },
      ],
    );
    return SliverMainAxisGroup(
      key: _resourceGroupKey,
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _ResourceTabsHeaderDelegate(
            tabBar: tabBar,
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          ),
        ),
        if (widget.progressMessage case final message? when message.isNotEmpty)
          SliverToBoxAdapter(
            child: FileExplorerProgressBanner(message: message),
          ),
        SliverLayoutBuilder(
          builder: (context, constraints) => SliverMainAxisGroup(
            slivers: [
              SliverTabPageView(
                position: _pagePosition,
                onDragStart: () {
                  _tabMotionGeneration++;
                  _motionTarget = null;
                  _dragScrollPending = true;
                  final offset = _resourceScrollOffset();
                  _unpinnedSwipeOffset = offset < 0 ? offset : null;
                  // Keep short destinations from shrinking the scroll range.
                  if (offset < 0 && !_fillResourceViewport) {
                    setState(() => _fillResourceViewport = true);
                  }
                  _beginTabTransition();
                  _pagePosition.stop(canceled: true);
                },
                onDragUpdate: _updatePagePosition,
                onDragEnd: _settlePagePosition,
                onDragCancel: () => _settlePagePosition(0),
                pages: [
                  for (final tab in _pageKinds)
                    SliverPadding(
                      key: ValueKey(tab),
                      padding: EdgeInsets.zero,
                      sliver: _pageFor(tab, context),
                    ),
                ],
              ),
              SliverLayoutBuilder(
                builder: (context, tailConstraints) {
                  final pageExtent =
                      tailConstraints.precedingScrollExtent -
                      constraints.precedingScrollExtent;
                  final tailExtent =
                      ((_fillResourceViewport
                                  ? constraints.viewportMainAxisExtent -
                                        tabBar.preferredSize.height
                                  : 0) -
                              pageExtent)
                          .clamp(0.0, double.infinity)
                          .toDouble();
                  return SliverToBoxAdapter(
                    child: SizedBox(height: tailExtent),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<WorkResourceTab> _buildPageKinds() => [
    WorkResourceTab.resources,
    WorkResourceTab.audio,
    if (_images.isNotEmpty) WorkResourceTab.images,
    if (widget.recommendationBuilder != null) WorkResourceTab.recommendations,
  ];

  List<WorkResourceTab> _visibleTabKinds(bool showRecommendations) => [
    for (final tab in _pageKinds)
      if (tab != WorkResourceTab.recommendations || showRecommendations) tab,
  ];

  WorkResourceTab _fallbackTab({
    required WorkResourceTab current,
    required int oldIndex,
    required List<WorkResourceTab> nextTabs,
  }) {
    if (nextTabs.contains(current)) return current;
    for (var index = oldIndex - 1; index >= 0; index--) {
      final previous = _tabKinds[index];
      if (nextTabs.contains(previous)) return previous;
    }
    if (nextTabs.contains(WorkResourceTab.audio)) return WorkResourceTab.audio;
    return nextTabs.first;
  }

  void _syncTabs({required bool showRecommendations}) {
    final nextPages = _buildPageKinds();
    final nextTabs = [
      for (final tab in nextPages)
        if (tab != WorkResourceTab.recommendations || showRecommendations) tab,
    ];
    if (listEquals(_pageKinds, nextPages) && listEquals(_tabKinds, nextTabs)) {
      return;
    }

    final oldIndex = (_motionTarget ?? _selected)
        .clamp(0, _tabKinds.length - 1)
        .toInt();
    final current = _tabKinds[oldIndex];
    final selectedTab = _fallbackTab(
      current: current,
      oldIndex: oldIndex,
      nextTabs: nextTabs,
    );
    final selected = nextTabs.indexOf(selectedTab);
    _tabMotionGeneration++;
    _transitionSource = null;
    _unpinnedSwipeOffset = null;
    _configuringTabs = true;
    _pagePosition.stop(canceled: true);
    _pagePosition.value = selected.toDouble();
    _pageKinds = nextPages;
    _tabKinds = nextTabs;
    _selected = selected;
    _motionTarget = null;
    _tabs.dispose();
    _tabs = TabController(
      length: nextTabs.length,
      initialIndex: selected,
      animationDuration: Duration.zero,
      vsync: this,
    );
    _configuringTabs = false;
  }

  Widget _pageFor(WorkResourceTab tab, BuildContext context) => switch (tab) {
    WorkResourceTab.resources => widget.resourceSliver,
    WorkResourceTab.audio => _audioList(context),
    WorkResourceTab.images => _imageGrid(context),
    WorkResourceTab.recommendations =>
      _recommendationVisited
          ? widget.recommendationBuilder!(context)
          : const SliverToBoxAdapter(child: SizedBox.shrink()),
  };

  void _visitRecommendation(WorkResourceTab tab) {
    if (tab != WorkResourceTab.recommendations || _recommendationVisited) {
      return;
    }
    setState(() => _recommendationVisited = true);
  }

  void _moveToTab(int index) {
    syncTabWithPagePosition(_tabs, _pagePosition.value);
    if ((_transitionSource == null && index == _selected) ||
        (_transitionSource != null && _motionTarget == index)) {
      return;
    }
    _unpinnedSwipeOffset = null;
    _visitRecommendation(_tabKinds[index]);
    _animateToPage(index.toDouble());
  }

  void _beginTabTransition() {
    if (_transitionSource != null) return;
    final source = _tabKinds[_selected.clamp(0, _tabKinds.length - 1)];
    _transitionSource = source;
    _tabScrollOffsets[source] = _resourceScrollOffset()
        .clamp(0.0, double.infinity)
        .toDouble();
  }

  Future<void> _animateToPage(double target) async {
    final page = target.clamp(0.0, (_tabs.length - 1).toDouble()).toDouble();
    final targetTab = _tabKinds[page.round()];
    if (_transitionSource == null && page.round() != _selected) {
      _beginTabTransition();
    }
    final generation = ++_tabMotionGeneration;
    _motionTarget = page.round();
    _updateImagePrefetch();
    _pagePosition.stop(canceled: true);
    if (_reduceMotion) {
      _pagePosition.value = page;
      await _restoreResourceOffset(targetTab, generation);
      return;
    }
    await _pagePosition.animateTo(
      page,
      duration: tabPageDuration,
      curve: Curves.ease,
    );
    await _restoreResourceOffset(targetTab, generation);
  }

  void _updatePagePosition(double pageDelta) {
    _motionTarget = null;
    final maxPage = (_tabs.length - 1).toDouble();
    _pagePosition.value = (_pagePosition.value + pageDelta)
        .clamp(0.0, maxPage)
        .toDouble();
    if (_dragScrollPending) {
      _dragScrollPending = false;
      if (_unpinnedSwipeOffset == null) {
        unawaited(_scrollToResourceTop());
      }
    }
    _scheduleImageInspection();
  }

  void _settlePagePosition(double velocity) {
    _dragScrollPending = false;
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
    if (selected != _selected ||
        (_tabKinds[selected] == WorkResourceTab.recommendations &&
            !_recommendationVisited)) {
      setState(() {
        _selected = selected;
        if (_tabKinds[selected] == WorkResourceTab.recommendations) {
          _recommendationVisited = true;
        }
      });
    }
    _scheduleImageInspection();
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
    final List<String> names = switch (_tabKinds[_selected]) {
      WorkResourceTab.resources => FileTreeUtils.collectNames(
        widget.fileTree,
        expandedFolders: widget.expandedFolders,
      ),
      WorkResourceTab.images =>
        _currentImagePage.map(FileTreeUtils.titleOf).toSet().toList(),
      WorkResourceTab.audio =>
        _audio.map((variant) => variant.title).toSet().toList(),
      WorkResourceTab.recommendations => const [],
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

  bool get _shouldPrepareImageTab {
    if (_images.isEmpty) return false;
    final target = _motionTarget;
    if (target != null) {
      return _tabKinds[target] == WorkResourceTab.images;
    }
    final page = _pagePosition.value;
    return _tabKinds[page.floor()] == WorkResourceTab.images ||
        _tabKinds[page.ceil()] == WorkResourceTab.images;
  }

  void _scheduleImageInspection() {
    if (_imageInspectionScheduled) return;
    _imageInspectionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _imageInspectionScheduled = false;
      if (mounted) _updateImagePrefetch();
    });
  }

  void _updateImagePrefetch() {
    final active = _shouldPrepareImageTab && _imageCacheWidth != null;
    if (!active) {
      _imagePrefetchQueue.update(
        items: const [],
        visible: const [],
        active: false,
      );
      return;
    }
    final pageImages = _currentImagePage;
    final visible = [
      for (final file in pageImages)
        if (_isImageVisible(file)) file,
    ];
    _imagePrefetchQueue.update(
      items: pageImages,
      visible: visible,
      // Wait for a real viewport cohort before warming anything. After the
      // page gate opens, keep prewarming even if the user scrolls past the grid.
      active: visible.isNotEmpty || _imagePageGatePassed.value,
    );
    if (!_imagePageGatePassed.value &&
        visible.isNotEmpty &&
        visible.every(_imageReady)) {
      setState(() => _imagePageGatePassed.value = true);
    }
  }

  bool _isImageVisible(dynamic file) {
    final itemContext = _imageItemKeys[file]?.currentContext;
    if (itemContext == null) return false;
    final renderObject = itemContext.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return false;
    }
    final viewport = RenderAbstractViewport.maybeOf(renderObject);
    final position = Scrollable.maybeOf(
      itemContext,
      axis: Axis.vertical,
    )?.position;
    if (viewport == null || position == null) return false;
    final leading = viewport.getOffsetToReveal(renderObject, 0).offset;
    final trailing =
        viewport.getOffsetToReveal(renderObject, 1).offset +
        position.viewportDimension;
    return trailing > position.pixels &&
        leading < position.pixels + position.viewportDimension;
  }

  Future<void> _prepareImage(dynamic file) async {
    final attempt = _imageAttempts[file] ?? 0;
    if (!mounted ||
        !_shouldPrepareImageTab ||
        !_currentImagePage.contains(file)) {
      return;
    }
    final future = _imageTargets.putIfAbsent(
      file,
      () => Future.sync(() => widget.resolveImage(file)),
    );
    final signal = _imageTargetSignals.putIfAbsent(
      file,
      () => ValueNotifier(null),
    );
    if (signal.value != future) signal.value = future;
    PreviewFileItem? target;
    try {
      target = await future;
    } catch (_) {
      if (!_shouldPrepareImageTab || !_currentImagePage.contains(file)) return;
      _markImageFailed(file, attempt);
      return;
    }
    if (!mounted ||
        !_shouldPrepareImageTab ||
        !_currentImagePage.contains(file) ||
        (_imageAttempts[file] ?? 0) != attempt) {
      return;
    }
    final cacheWidth = _imageCacheWidth;
    if (target == null) {
      _markImageFailed(file, attempt);
      return;
    }
    _resolvedImageTargets[file] = target;
    if (cacheWidth == null) {
      return;
    }
    ImageStream? stream;
    ImageStreamListener? listener;
    try {
      final provider = CachedImageWidget.imageProvider(
        imageUrl: target.url,
        hash: target.hash,
        cacheWidth: cacheWidth,
      );
      stream = provider.resolve(createLocalImageConfiguration(context));
      listener = ImageStreamListener((info, _) {
        final ratio = info.image.width / info.image.height;
        info.dispose();
        if (mounted &&
            _shouldPrepareImageTab &&
            _currentImagePage.contains(file) &&
            (_imageAttempts[file] ?? 0) == attempt) {
          _reportImageAspectRatio(file, ratio);
        }
      }, onError: (error, stackTrace) => _markImageFailed(file, attempt));
      stream.addListener(listener);
      await precacheImage(
        provider,
        context,
        onError: (error, stackTrace) => _markImageFailed(file, attempt),
      );
      _imagePrefetchQueue.retainImage((file, attempt, cacheWidth), stream);
    } catch (_) {
      _markImageFailed(file, attempt);
    } finally {
      if (stream != null && listener != null) {
        stream.removeListener(listener);
      }
    }
  }

  bool _imageReady(dynamic file) =>
      _imageAspectRatios[file]?.value != null ||
      _imageFailures[file]?.value == true;

  void _reportImageAspectRatio(dynamic file, double ratio) {
    if (!mounted ||
        !_shouldPrepareImageTab ||
        !_currentImagePage.contains(file)) {
      return;
    }
    final signal = _imageAspectRatios.putIfAbsent(
      file,
      () => ValueNotifier(null),
    );
    if (signal.value == ratio) return;
    signal.value = ratio;
    _scheduleImageInspection();
  }

  void _markImageFailed(dynamic file, int attempt) {
    if (!mounted ||
        !_shouldPrepareImageTab ||
        (_imageAttempts[file] ?? 0) != attempt ||
        !_currentImagePage.contains(file)) {
      return;
    }
    final signal = _imageFailures.putIfAbsent(file, () => ValueNotifier(false));
    if (!signal.value) signal.value = true;
    _scheduleImageInspection();
  }

  List<dynamic> get _currentImagePage {
    final start = (_imagePage - 1) * _imagesPerPage;
    return _images.skip(start).take(_imagesPerPage).toList(growable: false);
  }

  Widget _imageGrid(BuildContext context) {
    final pageImages = _currentImagePage;
    final loading = _shouldPrepareImageTab && !_imagePageGatePassed.value;
    return _SliverLoadingOverlay(
      loading: loading,
      sliver: SliverMainAxisGroup(
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
              final cardWidth =
                  (constraints.crossAxisExtent -
                      metrics.padding.horizontal -
                      metrics.spacing * (metrics.crossAxisCount - 1)) /
                  metrics.crossAxisCount;
              _imageCacheWidth =
                  (cardWidth * MediaQuery.devicePixelRatioOf(context)).ceil();
              _scheduleImageInspection();
              return SliverPadding(
                padding: metrics.padding,
                sliver: SliverMasonryGridTail(
                  itemCount: pageImages.length,
                  child: SliverMasonryGrid.count(
                    crossAxisCount: metrics.crossAxisCount,
                    crossAxisSpacing: metrics.spacing,
                    mainAxisSpacing: metrics.spacing,
                    childCount: pageImages.length,
                    itemBuilder: (context, index) {
                      final file = pageImages[index];
                      final itemKey = _imageItemKeys.putIfAbsent(
                        file,
                        GlobalKey.new,
                      );
                      final imageAspectRatio = _imageAspectRatios.putIfAbsent(
                        file,
                        () => ValueNotifier(null),
                      );
                      final imageFailure = _imageFailures.putIfAbsent(
                        file,
                        () => ValueNotifier(false),
                      );
                      final imageTarget = _imageTargetSignals.putIfAbsent(
                        file,
                        () => ValueNotifier(_imageTargets[file]),
                      );
                      final attempt = _imageAttempts[file] ?? 0;
                      return NotificationListener<
                        SizeChangedLayoutNotification
                      >(
                        onNotification: (_) {
                          _scheduleImageInspection();
                          return false;
                        },
                        child: SizedBox(
                          key: itemKey,
                          child: SizeChangedLayoutNotifier(
                            child: ValueListenableBuilder<Future<PreviewFileItem?>?>(
                              valueListenable: imageTarget,
                              builder: (context, future, _) => FutureBuilder<PreviewFileItem?>(
                                key: ObjectKey(file),
                                future: future,
                                initialData: _resolvedImageTargets[file],
                                builder: (context, snapshot) {
                                  final targetFutureFailed =
                                      snapshot.hasError ||
                                      (snapshot.connectionState ==
                                              ConnectionState.done &&
                                          snapshot.data == null);
                                  final target = snapshot.data;
                                  return ValueListenableBuilder<bool>(
                                    valueListenable: imageFailure,
                                    builder: (context, hasImageFailed, _) {
                                      final targetFailed =
                                          targetFutureFailed ||
                                          (hasImageFailed && target == null);
                                      return ValueListenableBuilder<double?>(
                                        valueListenable: imageAspectRatio,
                                        builder: (context, knownAspectRatio, _) {
                                          final aspectRatio =
                                              knownAspectRatio ?? 2 / 3;
                                          return ValueListenableBuilder<bool>(
                                            valueListenable:
                                                _imagePageGatePassed,
                                            builder: (context, pageReady, _) => Visibility(
                                              visible:
                                                  pageReady &&
                                                  (knownAspectRatio != null ||
                                                      hasImageFailed ||
                                                      targetFailed ||
                                                      attempt > 0),
                                              maintainSize: true,
                                              maintainAnimation: true,
                                              maintainState: true,
                                              child: Card(
                                                margin: EdgeInsets.zero,
                                                clipBehavior: Clip.antiAlias,
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        workCoverCompactRadius,
                                                      ),
                                                ),
                                                child: InkWell(
                                                  onTap: () =>
                                                      widget.onImageTap(file),
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .stretch,
                                                    children: [
                                                      WorkCoverClip(
                                                        cornerRadius:
                                                            workCoverCompactRadius,
                                                        child: AspectRatio(
                                                          aspectRatio:
                                                              aspectRatio,
                                                          child: targetFailed
                                                              ? Center(
                                                                  child: IconButton(
                                                                    tooltip: S
                                                                        .of(
                                                                          context,
                                                                        )
                                                                        .retry,
                                                                    icon: const Icon(
                                                                      Icons
                                                                          .broken_image_outlined,
                                                                    ),
                                                                    onPressed: () =>
                                                                        _retryImage(
                                                                          file,
                                                                        ),
                                                                  ),
                                                                )
                                                              : target == null
                                                              ? const TickerMode(
                                                                  enabled:
                                                                      false,
                                                                  child: Center(
                                                                    child:
                                                                        CircularProgressIndicator(),
                                                                  ),
                                                                )
                                                              : LayoutBuilder(
                                                                  builder: (context, _) => CachedImageWidget(
                                                                    key: ValueKey(
                                                                      attempt,
                                                                    ),
                                                                    imageUrl:
                                                                        target
                                                                            .url,
                                                                    hash: target
                                                                        .hash,
                                                                    cacheWidth:
                                                                        _imageCacheWidth!,
                                                                    fadeInDuration:
                                                                        Duration
                                                                            .zero,
                                                                    fadeOutDuration:
                                                                        Duration
                                                                            .zero,
                                                                    onRetry: () =>
                                                                        _retryImage(
                                                                          file,
                                                                        ),
                                                                    onAspectRatio: (ratio) {
                                                                      if (mounted &&
                                                                          _shouldPrepareImageTab &&
                                                                          _currentImagePage.contains(
                                                                            file,
                                                                          ) &&
                                                                          _imageAspectRatios[file] ==
                                                                              imageAspectRatio &&
                                                                          imageAspectRatio.value !=
                                                                              ratio) {
                                                                        imageAspectRatio.value =
                                                                            ratio;
                                                                      }
                                                                    },
                                                                    onImageError: () {
                                                                      if (mounted &&
                                                                          _shouldPrepareImageTab &&
                                                                          _currentImagePage.contains(
                                                                            file,
                                                                          ) &&
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
                                                        padding:
                                                            const EdgeInsets.all(
                                                              8,
                                                            ),
                                                        child: Text(
                                                          _displayName(
                                                            FileTreeUtils.titleOf(
                                                              file,
                                                            ),
                                                          ),
                                                          style: Theme.of(context)
                                                              .textTheme
                                                              .titleSmall
                                                              ?.copyWith(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                                height: 1.1,
                                                                fontSize:
                                                                    MediaQuery.orientationOf(
                                                                          context,
                                                                        ) ==
                                                                        Orientation
                                                                            .landscape
                                                                    ? 14.5
                                                                    : 12,
                                                              ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
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
      ),
      overlay: loading
          ? ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: const Center(
                child: CircularProgressIndicator(
                  key: ValueKey('work-resource-images-loading'),
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  void _changeImagePage(int page) {
    final maxPage = (_images.length / _imagesPerPage).ceil();
    if (page < 1 || page > maxPage || page == _imagePage) return;
    _imagePrefetchQueue.update(
      items: const [],
      visible: const [],
      active: false,
    );
    setState(() {
      _imagePage = page;
      _imagePageGatePassed.value = false;
    });
    _tabScrollOffsets[WorkResourceTab.images] = 0;
    unawaited(_scrollToResourceTop(animate: true));
  }

  double _resourceScrollOffset() {
    final position = _verticalPosition;
    final renderObject = _resourceGroupKey.currentContext?.findRenderObject();
    if (position == null ||
        !position.hasContentDimensions ||
        renderObject == null) {
      return 0;
    }
    final viewport = RenderAbstractViewport.maybeOf(renderObject);
    if (viewport == null) return 0;
    final resourceTop = viewport.getOffsetToReveal(renderObject, 0).offset;
    return position.pixels - resourceTop;
  }

  Future<void> _restoreResourceOffset(
    WorkResourceTab tab,
    int generation,
  ) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _tabMotionGeneration) return;
    final position = _verticalPosition;
    final renderObject = _resourceGroupKey.currentContext?.findRenderObject();
    final viewport = renderObject == null
        ? null
        : RenderAbstractViewport.maybeOf(renderObject);
    if (position != null &&
        position.hasContentDimensions &&
        renderObject != null &&
        viewport != null) {
      final resourceTop = viewport.getOffsetToReveal(renderObject, 0).offset;
      final offset =
          (resourceTop + (_unpinnedSwipeOffset ?? _tabScrollOffsets[tab] ?? 0))
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble();
      if (position.pixels != offset) position.jumpTo(offset);
    }
    if (generation == _tabMotionGeneration) {
      _transitionSource = null;
      _motionTarget = null;
      _unpinnedSwipeOffset = null;
    }
  }

  Future<void> _scrollToResourceTop({bool animate = false}) async {
    await WidgetsBinding.instance.endOfFrame;
    final groupContext = _resourceGroupKey.currentContext;
    if (!mounted || groupContext == null || !groupContext.mounted) {
      return;
    }
    await Scrollable.ensureVisible(
      groupContext,
      alignment: 0,
      duration: animate && !MediaQuery.disableAnimationsOf(groupContext)
          ? UiMotion.travel
          : Duration.zero,
      curve: UiMotion.curve,
    );
  }

  void _retryImage(dynamic file) {
    setState(() {
      _imageFailures[file]?.value = false;
      _imageTargets.remove(file);
      _resolvedImageTargets.remove(file);
      _imageTargetSignals[file]?.value = null;
      _imageAttempts[file] = (_imageAttempts[file] ?? 0) + 1;
    });
    _scheduleImageInspection();
  }
}

class _ResourceTabsHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _ResourceTabsHeaderDelegate({
    required this.tabBar,
    required this.backgroundColor,
  });

  final TabBar tabBar;
  final Color backgroundColor;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => SizedBox.expand(
    child: Material(color: backgroundColor, child: tabBar),
  );

  @override
  bool shouldRebuild(_ResourceTabsHeaderDelegate oldDelegate) =>
      tabBar != oldDelegate.tabBar ||
      backgroundColor != oldDelegate.backgroundColor;
}

class _SliverLoadingOverlay extends MultiChildRenderObjectWidget {
  _SliverLoadingOverlay({
    required Widget sliver,
    required this.loading,
    required Widget overlay,
  }) : super(children: [sliver, overlay]);

  final bool loading;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSliverLoadingOverlay(loading);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSliverLoadingOverlay renderObject,
  ) {
    renderObject.loading = loading;
  }
}

class _SliverLoadingOverlayParentData extends SliverPhysicalParentData
    with ContainerParentDataMixin<RenderObject> {}

class _RenderSliverLoadingOverlay extends RenderSliver
    with
        ContainerRenderObjectMixin<
          RenderObject,
          _SliverLoadingOverlayParentData
        > {
  _RenderSliverLoadingOverlay(this._loading);

  bool _loading;

  set loading(bool value) {
    if (_loading == value) return;
    _loading = value;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  RenderSliver get _sliver => firstChild! as RenderSliver;
  RenderBox get _overlay => childAfter(_sliver)! as RenderBox;

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! _SliverLoadingOverlayParentData) {
      child.parentData = _SliverLoadingOverlayParentData();
    }
  }

  @override
  void performLayout() {
    final sliver = _sliver;
    sliver.layout(constraints, parentUsesSize: true);
    final sliverGeometry = sliver.geometry!;
    geometry = sliverGeometry;
    (_parentData(sliver)).paintOffset = Offset.zero;

    final overlay = _overlay;
    if (!_loading || sliverGeometry.scrollOffsetCorrection != null) {
      overlay.layout(BoxConstraints.tight(Size.zero));
      _parentData(overlay).paintOffset = Offset.zero;
      return;
    }

    final size = constraints.axis == Axis.vertical
        ? Size(constraints.crossAxisExtent, sliverGeometry.paintExtent)
        : Size(sliverGeometry.paintExtent, constraints.crossAxisExtent);
    overlay.layout(BoxConstraints.tight(size), parentUsesSize: true);
    _parentData(overlay).paintOffset = Offset.zero;
  }

  _SliverLoadingOverlayParentData _parentData(RenderObject child) =>
      child.parentData! as _SliverLoadingOverlayParentData;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (geometry?.visible != true) return;
    final child = _loading ? _overlay : _sliver;
    context.paintChild(child, offset + _parentData(child).paintOffset);
  }

  @override
  bool hitTestChildren(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) =>
      !_loading &&
      _sliver.hitTest(
        result,
        mainAxisPosition: mainAxisPosition,
        crossAxisPosition: crossAxisPosition,
      );

  @override
  bool hitTestSelf({
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) => _loading;

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    visitor(_loading ? _overlay : _sliver);
  }

  @override
  double childMainAxisPosition(covariant RenderObject child) => 0;

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    _parentData(child).applyPaintTransform(transform);
  }
}
