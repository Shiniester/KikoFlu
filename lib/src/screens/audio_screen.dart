import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/my_reviews_provider.dart';
import '../providers/my_tabs_display_provider.dart';
import '../providers/collection_layout_provider.dart';
import '../providers/works_provider.dart' show LayoutType;
import '../utils/scroll_optimization.dart';
import '../utils/ui_tokens.dart';
import '../providers/auth_provider.dart';
import '../utils/server_utils.dart';
import '../utils/l10n_extensions.dart';
import '../widgets/works_grid_view.dart';
import '../widgets/virtualized_sliver_collection.dart';
import '../widgets/floating_feed_toolbar.dart';
import '../widgets/library_tab_strip.dart';
import '../widgets/audio_account_prompt.dart';
import '../widgets/download_fab.dart';
import '../providers/download_provider.dart';
import '../models/search_query.dart';
import 'downloads_screen.dart';
import 'local_downloads_screen.dart';
import 'subtitle_library_screen.dart';
import 'playlists_screen.dart';
import 'history_screen.dart';
import '../widgets/sort_dialog.dart';
import '../widgets/global_audio_player_wrapper.dart';
import '../models/sort_options.dart';
import '../utils/subtitle_filter.dart';
import '../utils/system_ui_style.dart';
import 'works_screen.dart';
import 'search_screen.dart';
export '../providers/my_reviews_provider.dart' show MyReviewLayoutType;

import '../../l10n/app_localizations.dart';

class AudioScreen extends ConsumerStatefulWidget {
  const AudioScreen({super.key});

  @override
  ConsumerState<AudioScreen> createState() => _AudioScreenState();
}

class _AudioScreenState extends ConsumerState<AudioScreen>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late TabController _tabController;
  final ValueNotifier<bool> _tabSwitcherVisible = ValueNotifier(true);
  int _lastTabIndex = 0;
  String _selectedTabId = 'home';
  List<String> _tabIds = const ['home'];

  @override
  bool get wantKeepAlive => true; // 保持状态不被销毁

  List<_TabInfo> _buildTabList(
    MyTabsDisplaySettings settings, {
    required double contentTop,
    required double collapsedToolbarTop,
  }) {
    final tabs = <_TabInfo>[
      _TabInfo(
        id: 'home',
        title: S.of(context).navHome,
        icon: Icons.home_outlined,
        widget: WorksScreen(
          toolbarTop: contentTop,
          collapsedToolbarTop: collapsedToolbarTop,
          primaryToolbarVisible: _tabSwitcherVisible,
          embedded: true,
          onSearchOnline: () => _openSearch(scope: SearchScope.globalWorks),
        ),
        showFab: true,
        fabWidget: const DownloadFab(),
      ),
    ];
    final authState = ref.watch(authProvider);
    final isOfficialServer = ServerUtils.isOfficialServer(authState.host);
    final activeDownloadCount =
        ref.watch(downloadSummaryProvider).valueOrNull?.active ?? 0;

    if (settings.showOnlineMarks) {
      tabs.add(
        _TabInfo(
          id: 'onlineMarks',
          title: S.of(context).onlineMarks,
          icon: Icons.bookmark,
          widget: _buildOnlineBookmarksTab(
            toolbarTop: contentTop,
            collapsedToolbarTop: collapsedToolbarTop,
          ),
          showFab: true,
          fabWidget: const DownloadFab(),
        ),
      );
    }

    // 历史记录
    tabs.add(
      _TabInfo(
        id: 'history',
        title: S.of(context).historyRecord,
        icon: Icons.history,
        widget: _buildSearchableCollectionTab(
          toolbarTop: contentTop,
          collapsedToolbarTop: collapsedToolbarTop,
          layoutKey: CollectionLayoutKey.history,
          child: HistoryScreen(topInset: contentTop + 56),
        ),
      ),
    );

    if (settings.showPlaylists && isOfficialServer) {
      tabs.add(
        _TabInfo(
          id: 'playlists',
          title: S.of(context).playlists,
          icon: Icons.playlist_play,
          widget: _buildSearchableCollectionTab(
            toolbarTop: contentTop,
            collapsedToolbarTop: collapsedToolbarTop,
            layoutKey: CollectionLayoutKey.playlists,
            child: PlaylistsScreen(topInset: contentTop + 56),
          ),
        ),
      );
    }

    // 已下载始终显示
    tabs.add(
      _TabInfo(
        id: 'downloads',
        title: S.of(context).downloaded,
        icon: Icons.download_done,
        widget: LocalDownloadsScreen(
          toolbarTop: contentTop,
          collapsedToolbarTop: collapsedToolbarTop,
          primaryToolbarVisible: _tabSwitcherVisible,
          onSearchOnline: () => _openSearch(scope: SearchScope.downloads),
        ),
        showFab: true,
        fabWidget: Badge(
          isLabelVisible: activeDownloadCount > 0,
          label: Text('$activeDownloadCount'),
          child: FloatingActionButton(
            onPressed: _navigateToDownloads,
            tooltip: S.of(context).downloadTasks,
            child: const Icon(Icons.download),
          ),
        ),
      ),
    );

    if (settings.showSubtitleLibrary) {
      tabs.add(
        _TabInfo(
          id: 'subtitleLibrary',
          title: S.of(context).subtitleLibrary,
          icon: Icons.subtitles,
          widget: SubtitleLibraryScreen(
            toolbarTop: contentTop,
            collapsedToolbarTop: collapsedToolbarTop,
            primaryToolbarVisible: _tabSwitcherVisible,
          ),
        ),
      );
    }

    return tabs;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 1, vsync: this);
    _tabController.addListener(_handleTabChanged);
    // 只在首次加载时获取数据，如果已有数据则不重新加载
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final notifier = ref.read(myReviewsProvider.notifier);
      await notifier.preferencesReady;
      if (!mounted) return;
      final myState = ref.read(myReviewsProvider);
      if (myState.works.isEmpty) {
        notifier.load(refresh: true);
      }
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    _tabSwitcherVisible.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _navigateToDownloads() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const DownloadsScreen()));
  }

  void _handleTabChanged() {
    if (_tabController.index == _lastTabIndex) return;
    _lastTabIndex = _tabController.index;
    if (_tabController.index < _tabIds.length) {
      _selectedTabId = _tabIds[_tabController.index];
    }
    _tabSwitcherVisible.value = true;
  }

  void _openSearch({required SearchScope scope, String? progressFilter}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => GlobalAudioPlayerWrapper(
          child: SearchScreen(
            showBackButton: true,
            scope: scope,
            progressFilter: progressFilter,
          ),
        ),
      ),
    );
  }

  Widget _buildSearchableCollectionTab({
    required double toolbarTop,
    required double collapsedToolbarTop,
    required CollectionLayoutKey layoutKey,
    required Widget child,
  }) {
    final horizontalPadding = FloatingToolbarLayout.horizontalPadding(context);
    return Stack(
      children: [
        Positioned.fill(child: child),
        FloatingToolbarPositionFollower(
          primaryToolbarVisible: _tabSwitcherVisible,
          visibleTop: toolbarTop,
          hiddenTop: collapsedToolbarTop,
          left: horizontalPadding,
          right: horizontalPadding,
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FloatingToolbarSurface(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingToolbarIconButton(
                    icon: Icons.search,
                    tooltip: S.of(context).searchOnlineWorks,
                    onPressed: () => _openSearch(
                      scope: layoutKey == CollectionLayoutKey.history
                          ? SearchScope.history
                          : SearchScope.playlists,
                    ),
                  ),
                  FloatingToolbarIconButton(
                    icon: switch (ref.watch(
                      collectionLayoutProvider(layoutKey),
                    )) {
                      LayoutType.bigGrid => Icons.grid_view,
                      LayoutType.smallGrid => Icons.grid_on,
                      LayoutType.list => Icons.view_list,
                    },
                    tooltip: S.of(context).layout,
                    onPressed: () => ref
                        .read(collectionLayoutProvider(layoutKey).notifier)
                        .cycle(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  bool _handleScrollNotification(ScrollNotification notification) =>
      updateLibraryToolbarVisibility(notification, _tabSwitcherVisible);

  IconData _getFilterIcon(MyReviewFilter filter) {
    switch (filter) {
      case MyReviewFilter.all:
        return Icons.all_inclusive;
      case MyReviewFilter.marked:
        return Icons.bookmark;
      case MyReviewFilter.listening:
        return Icons.headphones;
      case MyReviewFilter.listened:
        return Icons.check_circle;
      case MyReviewFilter.replay:
        return Icons.replay;
      case MyReviewFilter.postponed:
        return Icons.schedule;
    }
  }

  void _showSortDialog() {
    final state = ref.read(myReviewsProvider);
    showDialog(
      context: context,
      builder: (context) => CommonSortDialog(
        title: S.of(context).sortOptions,
        currentOption: state.sortType,
        currentDirection: state.sortOrder,
        availableOptions: const [
          SortOrder.updatedAt,
          SortOrder.release,
          SortOrder.review,
          SortOrder.dlCount,
        ],
        onSort: (option, direction) {
          ref.read(myReviewsProvider.notifier).changeSort(option, direction);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // 必须调用以保持状态

    final tabsSettings = ref.watch(myTabsDisplayProvider);
    final topPadding = MediaQuery.paddingOf(context).top;
    final horizontalPadding = FloatingToolbarLayout.horizontalPadding(context);
    final tabSwitcherTop = topPadding + 8;
    final contentTop = tabSwitcherTop + kTextTabBarHeight + 8;
    final collapsedToolbarTop = tabSwitcherTop;
    final tabs = _buildTabList(
      tabsSettings,
      contentTop: contentTop,
      collapsedToolbarTop: collapsedToolbarTop,
    );

    final tabDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kTabScrollDuration;
    // 更换控制器会让 TabBarView 停止滚动并保留当前目标页。
    var selectedIndex = tabs.indexWhere((tab) => tab.id == _selectedTabId);
    if (selectedIndex < 0) {
      selectedIndex = 0;
      _selectedTabId = tabs.first.id;
    }
    _tabIds = tabs.map((tab) => tab.id).toList(growable: false);

    if (_tabController.length != tabs.length ||
        _tabController.animationDuration != tabDuration ||
        _tabController.index != selectedIndex) {
      _tabController.removeListener(_handleTabChanged);
      _tabController.dispose();
      _tabController = TabController(
        length: tabs.length,
        vsync: this,
        initialIndex: selectedIndex,
        animationDuration: tabDuration,
      );
      _tabController.addListener(_handleTabChanged);
      _lastTabIndex = _tabController.index;
    }

    final systemOverlayStyle = transparentSystemBarsForBrightness(
      Theme.of(context).brightness,
    );

    return AnnotatedRegion(
      value: systemOverlayStyle,
      child: Scaffold(
        floatingActionButton: AnimatedBuilder(
          animation: _tabController,
          builder: (context, child) {
            final currentIndex = _tabController.index;
            if (currentIndex >= 0 && currentIndex < tabs.length) {
              final currentTab = tabs[currentIndex];
              if (currentTab.showFab && currentTab.fabWidget != null) {
                return currentTab.fabWidget!;
              }
            }
            return const SizedBox.shrink();
          },
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: NotificationListener<ScrollNotification>(
                onNotification: _handleScrollNotification,
                child: TabBarView(
                  controller: _tabController,
                  children: tabs
                      .map(
                        (tab) => _AudioTabPage(
                          key: ValueKey(tab.id),
                          child: tab.widget,
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ProgressiveTopScrim(height: topPadding + 12),
            ),
            Positioned(
              top: tabSwitcherTop,
              left: horizontalPadding,
              right: horizontalPadding,
              child: LibraryTabStrip(
                controller: _tabController,
                visible: _tabSwitcherVisible,
                motionKey: const ValueKey('my-tab-switcher'),
                tabs: tabs
                    .map(
                      (tab) => Tab(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(tab.icon, size: 18),
                            const SizedBox(width: 6),
                            Text(tab.title),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOnlineBookmarksTab({
    required double toolbarTop,
    required double collapsedToolbarTop,
  }) {
    if (ref.watch(authProvider).isAnonymous) return const AudioAccountPrompt();
    final state = ref.watch(myReviewsProvider);
    final horizontalPadding = FloatingToolbarLayout.horizontalPadding(context);

    return Stack(
      children: [
        Positioned.fill(child: _buildBody(state, topPadding: toolbarTop + 56)),
        FloatingToolbarPositionFollower(
          primaryToolbarVisible: _tabSwitcherVisible,
          visibleTop: toolbarTop,
          hiddenTop: collapsedToolbarTop,
          left: horizontalPadding,
          right: horizontalPadding,
          child: FloatingFeedToolbar(
            modeActions: [
              for (final filter in MyReviewFilter.values)
                FloatingFeedModeAction(
                  icon: _getFilterIcon(filter),
                  label: filter.localizedLabel(context),
                  isSelected: state.filter == filter,
                  onPressed: () =>
                      ref.read(myReviewsProvider.notifier).changeFilter(filter),
                ),
            ],
            toolActions: [
              FloatingFeedToolAction(
                icon: Icons.search,
                tooltip: S.of(context).searchOnlineWorks,
                onPressed: () => _openSearch(
                  scope: SearchScope.onlineMarks,
                  progressFilter: state.filter.value,
                ),
              ),
              FloatingFeedToolAction(
                icon: switch (state.layoutType) {
                  MyReviewLayoutType.bigGrid => Icons.grid_view,
                  MyReviewLayoutType.smallGrid => Icons.grid_on,
                  MyReviewLayoutType.list => Icons.view_list,
                },
                tooltip: S.of(context).layout,
                onPressed: () =>
                    ref.read(myReviewsProvider.notifier).toggleLayoutType(),
              ),
              FloatingFeedToolAction(
                icon:
                    SubtitleFilterMode.fromValue(state.subtitleFilter).isActive
                    ? Icons.closed_caption
                    : Icons.closed_caption_off,
                tooltip: S.of(context).subtitleFilter,
                isSelected: SubtitleFilterMode.fromValue(
                  state.subtitleFilter,
                ).isActive,
                onPressed: () =>
                    ref.read(myReviewsProvider.notifier).toggleSubtitleFilter(),
              ),
              FloatingFeedToolAction(
                icon: Icons.sort,
                tooltip: S.of(context).sort,
                onPressed: _showSortDialog,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBody(MyReviewsState state, {double topPadding = 0}) {
    if (state.error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              S.of(context).loadFailed,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              state.error!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => ref.read(myReviewsProvider.notifier).refresh(),
              icon: const Icon(Icons.refresh),
              label: Text(S.of(context).retry),
            ),
          ],
        ),
      );
    }

    if (state.isLoading && state.works.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final layoutType = switch (state.layoutType) {
      MyReviewLayoutType.bigGrid => LayoutType.bigGrid,
      MyReviewLayoutType.smallGrid => LayoutType.smallGrid,
      MyReviewLayoutType.list => LayoutType.list,
    };

    return WorksGridView(
      works: state.works,
      layoutType: layoutType,
      scrollController: _scrollController,
      physics: ScrollOptimization.physics,
      isLoading: state.isLoading,
      isRefreshing: state.isLoading && state.works.isNotEmpty,
      isLoadingMore: state.isLoadingMore,
      hasMore: state.hasMore,
      error: state.error,
      loadMoreError: state.loadMoreError,
      onRetry: () => ref.read(myReviewsProvider.notifier).refresh(),
      onRefresh: () => ref.read(myReviewsProvider.notifier).refresh(),
      pagination: VirtualizedPagination(
        currentPage: state.currentPage,
        pageSize: state.layoutType == MyReviewLayoutType.list
            ? state.pageSize
            : state.effectivePageSize,
        totalCount: state.totalCount,
        hasMore: state.hasMore,
        isLoading: state.isLoading || state.isRefreshing,
        onPreviousPage: ref.read(myReviewsProvider.notifier).previousPage,
        onNextPage: ref.read(myReviewsProvider.notifier).nextPage,
        onGoToPage: ref.read(myReviewsProvider.notifier).goToPage,
        nextPageOnOverscroll: true,
        scrollDuration: UiMotion.travel,
        scrollCurve: UiMotion.curve,
        showWhenEmpty: true,
      ),
      fillEmptyViewport: false,
      padding: state.layoutType == MyReviewLayoutType.list
          ? EdgeInsets.fromLTRB(8, topPadding + 8, 8, 8)
          : MediaQuery.orientationOf(context) == Orientation.landscape
          ? EdgeInsets.fromLTRB(24, topPadding + 8, 24, 24)
          : EdgeInsets.fromLTRB(8, topPadding + 8, 8, 8),
    );
  }
}

class _AudioTabPage extends StatefulWidget {
  const _AudioTabPage({super.key, required this.child});

  final Widget child;

  @override
  State<_AudioTabPage> createState() => _AudioTabPageState();
}

class _AudioTabPageState extends State<_AudioTabPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

// Helper class to organize tab information
class _TabInfo {
  final String id;
  final String title;
  final IconData icon;
  final Widget widget;
  final bool showFab;
  final Widget? fabWidget;

  const _TabInfo({
    required this.id,
    required this.title,
    required this.icon,
    required this.widget,
    this.showFab = false,
    this.fabWidget,
  });
}
