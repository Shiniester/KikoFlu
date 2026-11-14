import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../models/audio_source.dart';
import '../models/search_query.dart';
import '../models/search_type.dart';
import '../models/sort_options.dart';
import '../providers/audio_source_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/collection_layout_provider.dart';
import '../providers/download_provider.dart';
import '../providers/history_provider.dart';
import '../providers/my_reviews_provider.dart';
import '../providers/my_tabs_display_provider.dart';
import '../providers/settings_provider.dart'
    show autoTranslateWorkDetailsProvider;
import '../providers/works_provider.dart'
    show DisplayMode, LayoutType, worksProvider;
import '../utils/l10n_extensions.dart';
import '../utils/scroll_optimization.dart';
import '../utils/server_utils.dart';
import '../utils/snackbar_util.dart';
import '../utils/subtitle_filter.dart';
import '../utils/ui_tokens.dart';
import '../widgets/app_bottom_dock_transition.dart';
import '../widgets/app_navigation_scope.dart';
import '../widgets/audio_account_prompt.dart';
import 'account_management_screen.dart';
import '../widgets/download_fab.dart';
import '../widgets/global_audio_player_wrapper.dart';
import '../widgets/library_content_transition.dart';
import '../widgets/library_page_scaffold.dart';
import '../widgets/sort_dialog.dart';
import '../widgets/tab_page_motion.dart';
import '../widgets/virtualized_sliver_collection.dart';
import '../widgets/player/player_route.dart';
import '../widgets/player/player_vertical_gestures.dart';
import '../widgets/works_grid_view.dart';
import 'downloads_screen.dart';
import 'blocked_items_screen.dart';
import 'history_screen.dart';
import 'local_downloads_screen.dart';
import 'playlists_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'subtitle_library_screen.dart';
import 'works_screen.dart';

class AudioScreen extends ConsumerStatefulWidget {
  const AudioScreen({super.key});

  @override
  ConsumerState<AudioScreen> createState() => _AudioScreenState();
}

class _AudioScreenState extends ConsumerState<AudioScreen>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scrollController = ScrollController();
  final _pages = PageController();
  final _pageTarget = ValueNotifier<int?>(null);
  final _contentTransition = GlobalKey<LibraryContentTransitionState>();
  final _downloadsKey = GlobalKey<LocalDownloadsScreenState>();
  final _subtitleKey = GlobalKey<SubtitleLibraryScreenState>();
  final _playlistsKey = GlobalKey<PlaylistsScreenState>();
  String _selectedPageId = 'home';
  List<String> _tabIds = const ['works'];
  int _pageRequest = 0;
  bool _changingDisplayMode = false;
  bool _reduceMotion = false;
  bool _retryingConnection = false;

  @override
  bool get wantKeepAlive => true;

  List<_TabInfo> _buildTabList(
    MyTabsDisplaySettings settings, {
    required AudioSource source,
    required bool isOfficialServer,
  }) {
    final tabs = <_TabInfo>[
      _TabInfo(
        id: 'works',
        title: S.of(context).navHome,
        icon: Icons.home_outlined,
        widget: const WorksScreen(embedded: true),
      ),
    ];

    for (final page in settings.pageOrder) {
      switch (page) {
        case 'onlineMarks':
          if (source == AudioSource.asmrOne && settings.showOnlineMarks) {
            tabs.add(
              _TabInfo(
                id: page,
                title: S.of(context).libraryMarks,
                icon: Icons.bookmark,
                widget: _buildOnlineBookmarksPage(),
              ),
            );
          }
          break;
        case 'history':
          tabs.add(
            _TabInfo(
              id: page,
              title: S.of(context).libraryHistory,
              icon: Icons.history,
              widget: const HistoryScreen(),
            ),
          );
          break;
        case 'playlists':
          if (source == AudioSource.asmrOne &&
              settings.showPlaylists &&
              isOfficialServer) {
            tabs.add(
              _TabInfo(
                id: page,
                title: S.of(context).libraryFavorites,
                icon: Icons.favorite_border,
                widget: PlaylistsScreen(key: _playlistsKey),
              ),
            );
          }
          break;
        case 'downloads':
          tabs.add(
            _TabInfo(
              id: page,
              title: S.of(context).libraryDownloads,
              icon: Icons.download_done,
              widget: LocalDownloadsScreen(
                key: _downloadsKey,
                embedded: true,
                onDrawerChanged: _refreshDrawer,
              ),
            ),
          );
          break;
        case 'subtitleLibrary':
          if (settings.showSubtitleLibrary) {
            tabs.add(
              _TabInfo(
                id: page,
                title: S.of(context).librarySubtitles,
                icon: Icons.subtitles,
                widget: SubtitleLibraryScreen(
                  key: _subtitleKey,
                  embedded: true,
                  onDrawerChanged: _refreshDrawer,
                ),
              ),
            );
          }
          break;
      }
    }

    return tabs;
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadMyReviewsIfNeeded();
    });
  }

  Future<void> _loadMyReviewsIfNeeded() async {
    if (ref.read(audioSourceProvider) != AudioSource.asmrOne) return;
    final notifier = ref.read(myReviewsProvider.notifier);
    await notifier.preferencesReady;
    if (!mounted || ref.read(audioSourceProvider) != AudioSource.asmrOne) {
      return;
    }
    final myState = ref.read(myReviewsProvider);
    if (myState.works.isEmpty && !myState.isLoading) {
      await notifier.load(refresh: true);
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    _pageTarget.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion && !_reduceMotion) {
      final target = _pageTarget.value;
      if (target != null && _pages.hasClients) {
        _pages.jumpToPage(target);
        _pageRequest++;
        _pageTarget.value = null;
      }
    }
    _reduceMotion = reduceMotion;
  }

  void _navigateToDownloads() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const DownloadsScreen()));
  }

  String _pageForDisplayMode(DisplayMode mode) => switch (mode) {
    DisplayMode.all => 'home',
    DisplayMode.popular => 'popular',
    DisplayMode.recommended => 'recommended',
  };

  String _selectedPhysicalPage(String pageId) =>
      pageId == 'home' || pageId == 'popular' || pageId == 'recommended'
      ? 'works'
      : pageId;

  Future<void> _selectPhysicalTab(
    int index, {
    required String selectedPageId,
    bool animate = true,
  }) async {
    if (index < 0 || index >= _tabIds.length) return;
    final request = ++_pageRequest;
    setState(() => _selectedPageId = selectedPageId);
    _pageTarget.value = index;
    await moveToTabPage(_pages, index, reduceMotion: !animate || _reduceMotion);
    if (!mounted || request != _pageRequest) return;
    _pageTarget.value = null;
  }

  bool get _worksPageAtRest =>
      _selectedPhysicalPage(_selectedPageId) == 'works' &&
      _pages.hasClients &&
      _pages.position.hasContentDimensions &&
      !_pages.position.isScrollingNotifier.value &&
      _pages.page == 0;

  void _selectWorksMode(DisplayMode mode, String pageId) {
    final previous = ref.read(worksProvider).displayMode;
    final samePhysicalPage = _worksPageAtRest;

    void change() {
      _changingDisplayMode = true;
      try {
        ref.read(worksProvider.notifier).setDisplayMode(mode);
        if (samePhysicalPage) {
          setState(() => _selectedPageId = pageId);
        } else {
          unawaited(_selectPhysicalTab(0, selectedPageId: pageId));
        }
      } finally {
        _changingDisplayMode = false;
      }
    }

    if (samePhysicalPage && previous != mode) {
      final transition = _contentTransition.currentState;
      if (transition == null) {
        change();
      } else {
        transition.animate(change, reverse: mode.index < previous.index);
      }
    } else {
      change();
    }
  }

  void _selectPage(String pageId) {
    if (pageId == 'popular' || pageId == 'recommended' || pageId == 'home') {
      final mode = switch (pageId) {
        'popular' => DisplayMode.popular,
        'recommended' => DisplayMode.recommended,
        _ => DisplayMode.all,
      };
      _selectWorksMode(mode, pageId);
      return;
    }
    final index = _tabIds.indexOf(pageId);
    unawaited(_selectPhysicalTab(index, selectedPageId: pageId));
  }

  Future<void> _selectSource(AudioSource source) async {
    final previous = ref.read(audioSourceProvider);
    if (previous == source) {
      _selectWorksMode(DisplayMode.all, 'home');
      return;
    }

    late Future<void> selection;
    void change() {
      _changingDisplayMode = true;
      try {
        selection = ref.read(audioSourceProvider.notifier).select(source);
        ref.read(worksProvider.notifier).setDisplayMode(DisplayMode.all);
        unawaited(
          _selectPhysicalTab(0, selectedPageId: 'home', animate: false),
        );
      } finally {
        _changingDisplayMode = false;
      }
    }

    final transition = _contentTransition.currentState;
    if (transition == null) {
      change();
    } else {
      transition.animate(change, reverse: source.index < previous.index);
    }
    await selection;
  }

  void _refreshDrawer() {
    if (mounted) setState(() {});
  }

  void _openAdvancedSearch() {
    if (_selectedPageId == 'subtitleLibrary') {
      pushBottomDockRoute(
        context,
        builder: (_) => const GlobalAudioPlayerWrapper(
          child: SubtitleLibraryScreen(searchPage: true),
        ),
      );
      return;
    }
    final scope = switch (_selectedPageId) {
      'onlineMarks' => SearchScope.onlineMarks,
      'history' => SearchScope.history,
      'playlists' => SearchScope.playlists,
      'downloads' => SearchScope.downloads,
      _ => SearchScope.globalWorks,
    };
    final progressFilter = scope == SearchScope.onlineMarks
        ? ref.read(myReviewsProvider).filter.value
        : null;
    pushWorkDetailRoute(
      context,
      builder: (_) => GlobalAudioPlayerWrapper(
        child: SearchScreen(
          showBackButton: true,
          scope: scope,
          progressFilter: progressFilter,
        ),
      ),
    );
  }

  bool _isPageAvailable(
    String page,
    MyTabsDisplaySettings settings, {
    required AudioSource source,
    required bool isOfficialServer,
  }) => switch (page) {
    'popular' => source == AudioSource.asmrOne,
    'recommended' => source == AudioSource.asmrOne,
    'onlineMarks' => source == AudioSource.asmrOne && settings.showOnlineMarks,
    'history' || 'downloads' => true,
    'playlists' =>
      source == AudioSource.asmrOne &&
          settings.showPlaylists &&
          isOfficialServer,
    'subtitleLibrary' => settings.showSubtitleLibrary,
    _ => false,
  };

  String _pageTitle(String page) {
    final s = S.of(context);
    return switch (page) {
      'popular' => s.displayModePopular,
      'recommended' => s.displayModeRecommended,
      'onlineMarks' => s.libraryMarks,
      'history' => s.libraryHistory,
      'playlists' => s.libraryFavorites,
      'downloads' => s.libraryDownloads,
      'subtitleLibrary' => s.librarySubtitles,
      _ => s.navHome,
    };
  }

  IconData _pageIcon(String page) => switch (page) {
    'popular' => Icons.local_fire_department,
    'recommended' => Icons.auto_awesome,
    'onlineMarks' => Icons.bookmark,
    'history' => Icons.history,
    'playlists' => Icons.favorite_border,
    'downloads' => Icons.download_done,
    'subtitleLibrary' => Icons.subtitles,
    _ => Icons.home_outlined,
  };

  IconData _layoutIcon(LayoutType layout) => switch (layout) {
    LayoutType.bigGrid => Icons.grid_view,
    LayoutType.smallGrid => Icons.grid_on,
    LayoutType.list => Icons.view_list,
  };

  List<Widget> _buildDrawerChildren({
    required MyTabsDisplaySettings settings,
    required AudioSource source,
    required bool isAnonymous,
    required bool isOfficialServer,
    required DisplayMode displayMode,
    required MyReviewsState marksState,
  }) {
    final s = S.of(context);
    final pages = settings.pageOrder
        .where(
          (page) => _isPageAvailable(
            page,
            settings,
            source: source,
            isOfficialServer: isOfficialServer,
          ),
        )
        .toList(growable: false);
    LibraryDrawerTile pageTile(String page) => LibraryDrawerTile(
      icon: _pageIcon(page),
      title: _pageTitle(page),
      selected: _selectedPageId == page,
      children: _selectedPageId == page
          ? _buildPageOptions(
              source: source,
              displayMode: displayMode,
              marksState: marksState,
            )
          : const [],
      onTap: () => _selectPage(page),
    );
    List<Widget> pageTiles(Set<String> pageIds) => [
      for (final page in pages)
        if (pageIds.contains(page)) pageTile(page),
    ];
    final children = <Widget>[
      LibraryDrawerSection(
        title: s.librarySources,
        children: [
          for (final audioSource in AudioSource.values)
            LibraryDrawerTile(
              icon: Icons.library_music_outlined,
              title: audioSource.label,
              selected: audioSource == source,
              onTap: () => _selectSource(audioSource),
            ),
        ],
      ),
      if (source == AudioSource.asmrOne)
        LibraryDrawerSection(
          title: s.libraryAccount,
          children: [
            LibraryDrawerTile(
              icon: Icons.account_circle_outlined,
              title: isAnonymous ? s.login : s.accountManagement,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AccountManagementScreen(),
                ),
              ),
            ),
            ...pageTiles(const {'onlineMarks', 'playlists'}),
          ],
        ),
      LibraryDrawerSection(
        title: s.libraryContent,
        children: [
          LibraryDrawerTile(
            icon: Icons.home_outlined,
            title: s.navHome,
            selected: _selectedPageId == 'home',
            children: _selectedPageId == 'home'
                ? _buildPageOptions(
                    source: source,
                    displayMode: displayMode,
                    marksState: marksState,
                  )
                : const [],
            onTap: () => _selectPage('home'),
          ),
          ...pageTiles(const {'popular', 'recommended'}),
        ],
      ),
      LibraryDrawerSection(
        title: s.libraryLocal,
        children: pageTiles(const {'history', 'downloads', 'subtitleLibrary'}),
      ),
      LibraryDrawerSection(
        title: s.libraryBrowseOptions,
        children: _buildBrowseOptions(source: source),
      ),
    ];
    return children;
  }

  List<Widget> _buildPageOptions({
    required AudioSource source,
    required DisplayMode displayMode,
    required MyReviewsState marksState,
  }) {
    final s = S.of(context);
    final options = <Widget>[];
    switch (_selectedPageId) {
      case 'home':
      case 'popular':
      case 'recommended':
        final worksState = ref.watch(worksProvider);
        options.addAll([
          if (source != AudioSource.jpAsmr)
            LibraryDrawerTile(
              icon:
                  SubtitleFilterMode.fromValue(
                    worksState.subtitleFilter,
                  ).isActive
                  ? Icons.closed_caption
                  : Icons.closed_caption_off,
              title: s.subtitleFilter,
              closeOnTap: false,
              selected: SubtitleFilterMode.fromValue(
                worksState.subtitleFilter,
              ).isActive,
              onTap: () =>
                  ref.read(worksProvider.notifier).toggleSubtitleFilter(),
            ),
          if (source != AudioSource.jpAsmr && displayMode == DisplayMode.all)
            LibraryDrawerTile(
              icon: Icons.sort,
              title: s.sort,
              subtitle: Text(
                worksState.sortOption.localizedLabel(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: _showWorksSortDialog,
            ),
          if (source == AudioSource.jpAsmr && displayMode == DisplayMode.all)
            LibraryDrawerTile(
              icon: Icons.shield_outlined,
              title: s.ageRatingLabel,
              subtitle: Text(
                worksState.japaneseAsmrAgeRating.localizedLabel(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: _showJapaneseAsmrAgeRatingDialog,
            ),
        ]);
        break;
      case 'onlineMarks':
        options.addAll([
          for (final filter in MyReviewFilter.values)
            LibraryDrawerTile(
              icon: _getFilterIcon(filter),
              title: filter.localizedLabel(context),
              selected: marksState.filter == filter,
              closeOnTap: false,
              onTap: () =>
                  ref.read(myReviewsProvider.notifier).changeFilter(filter),
            ),
          LibraryDrawerTile(
            icon:
                SubtitleFilterMode.fromValue(marksState.subtitleFilter).isActive
                ? Icons.closed_caption
                : Icons.closed_caption_off,
            title: s.subtitleFilter,
            selected: SubtitleFilterMode.fromValue(
              marksState.subtitleFilter,
            ).isActive,
            closeOnTap: false,
            onTap: () =>
                ref.read(myReviewsProvider.notifier).toggleSubtitleFilter(),
          ),
          LibraryDrawerTile(
            icon: Icons.sort,
            title: s.sort,
            onTap: _showSortDialog,
          ),
        ]);
        break;
      case 'history':
        options.add(
          LibraryDrawerTile(
            key: const ValueKey('audio-queue-history-entry'),
            icon: Icons.queue_music,
            title: s.playbackQueueHistory,
            onTap: () => openAudioPlayer<void>(
              context,
              initialSurface: PlayerInitialSurface.queue,
              initialQueueHistory: true,
            ),
          ),
        );
        if (ref.watch(historyProvider).records.isNotEmpty) {
          options.add(
            LibraryDrawerTile(
              icon: Icons.delete_outline,
              title: s.clearHistory,
              onTap: _showClearHistoryConfirmation,
            ),
          );
        }
        break;
      case 'playlists':
        options.addAll([
          LibraryDrawerTile(
            icon: Icons.add,
            title: s.createPlaylist,
            onTap: () => _playlistsKey.currentState?.showCreatePlaylistDialog(),
          ),
        ]);
        break;
      case 'downloads':
        options.addAll(_downloadBrowseOptions(s));
        break;
      case 'subtitleLibrary':
        options.addAll(_subtitleBrowseOptions(s));
        break;
    }
    return options;
  }

  List<Widget> _buildBrowseOptions({required AudioSource source}) {
    final s = S.of(context);
    final autoTranslate = ref.watch(autoTranslateWorkDetailsProvider);
    return [
      LibraryDrawerTile(
        title: s.layout,
        icon: _layoutIcon(ref.watch(audioLayoutProvider)),
        closeOnTap: false,
        onTap: () => ref.read(audioLayoutProvider.notifier).cycle(),
      ),
      LibraryDrawerTile(
        icon: Icons.block,
        title: s.block,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => BlockedItemsScreen(source: source),
          ),
        ),
      ),
      LibraryDrawerTile(
        icon: Icons.translate,
        title: s.autoTranslateWorkDetails,
        trailing: Switch(
          value: autoTranslate,
          onChanged: (enabled) => ref
              .read(autoTranslateWorkDetailsProvider.notifier)
              .setEnabled(enabled),
        ),
        closeOnTap: false,
        onTap: () => ref
            .read(autoTranslateWorkDetailsProvider.notifier)
            .setEnabled(!ref.read(autoTranslateWorkDetailsProvider)),
      ),
    ];
  }

  List<Widget> _downloadBrowseOptions(S s) {
    final options = <Widget>[];
    final downloads = _downloadsKey.currentState;
    if (downloads != null) {
      final allSelected = downloads.allSelected;
      options.addAll([
        LibraryDrawerTile(
          icon: downloads.isSelectionMode ? Icons.close : Icons.checklist,
          title: downloads.isSelectionMode ? s.exitSelection : s.select,
          subtitle: downloads.isSelectionMode
              ? Text(s.selectedCount(downloads.selectedCount))
              : null,
          onTap: downloads.toggleSelectionModeFromDrawer,
        ),
        if (downloads.isSelectionMode)
          LibraryDrawerTile(
            icon: Icons.select_all,
            title: allSelected ? s.deselectAll : s.selectAll,
            onTap: allSelected
                ? downloads.deselectAllFromDrawer
                : downloads.selectAllFromDrawer,
          ),
        if (downloads.isSelectionMode && downloads.selectedCount > 0)
          LibraryDrawerTile(
            icon: Icons.delete_outline,
            title: s.delete,
            onTap: downloads.deleteSelectedFromDrawer,
          ),
      ]);
    }
    options.addAll([
      LibraryDrawerTile(
        icon: Icons.sort,
        title: S.of(context).sortOptions,
        onTap: downloads?.showSortDialogFromDrawer,
      ),
      LibraryDrawerTile(
        icon: Icons.refresh,
        title: S.of(context).reload,
        onTap: downloads?.refreshMetadataFromDrawer,
      ),
      if (Theme.of(context).platform == TargetPlatform.windows ||
          Theme.of(context).platform == TargetPlatform.macOS ||
          Theme.of(context).platform == TargetPlatform.linux)
        LibraryDrawerTile(
          icon: Icons.folder_open,
          title: S.of(context).openFolder,
          onTap: downloads?.openDownloadFolderFromDrawer,
        ),
    ]);
    return options;
  }

  List<Widget> _subtitleBrowseOptions(S s) {
    final subtitles = _subtitleKey.currentState;
    if (subtitles == null) return const [];
    final allSelected = subtitles.allSelected;
    return [
      LibraryDrawerTile(
        icon: Icons.add,
        title: s.importSubtitle,
        onTap: subtitles.importFromDrawer,
      ),
      if (subtitles.canNavigateUp)
        LibraryDrawerTile(
          icon: Icons.arrow_upward,
          title: s.back,
          onTap: subtitles.navigateUpFromDrawer,
        ),
      LibraryDrawerTile(
        icon: subtitles.isSelectionMode ? Icons.close : Icons.checklist,
        title: subtitles.isSelectionMode ? s.exitSelection : s.select,
        subtitle: subtitles.isSelectionMode
            ? Text(s.selectedCount(subtitles.selectedCount))
            : null,
        onTap: subtitles.toggleSelectionFromDrawer,
      ),
      if (subtitles.isSelectionMode)
        LibraryDrawerTile(
          icon: Icons.select_all,
          title: allSelected ? s.deselectAll : s.selectAll,
          onTap: allSelected
              ? subtitles.deselectAllFromDrawer
              : subtitles.selectAllFromDrawer,
        ),
      if (subtitles.isSelectionMode && subtitles.selectedCount > 0)
        LibraryDrawerTile(
          icon: Icons.delete_outline,
          title: s.delete,
          onTap: subtitles.deleteSelectedFromDrawer,
        ),
      LibraryDrawerTile(
        icon: Icons.refresh,
        title: s.reload,
        onTap: subtitles.refreshFromDrawer,
      ),
      LibraryDrawerTile(
        icon: Icons.info_outline,
        title: s.subtitleLibraryGuide,
        onTap: subtitles.showGuideFromDrawer,
      ),
      if (Theme.of(context).platform == TargetPlatform.windows ||
          Theme.of(context).platform == TargetPlatform.macOS ||
          Theme.of(context).platform == TargetPlatform.linux)
        LibraryDrawerTile(
          icon: Icons.folder_open,
          title: s.openFolder,
          onTap: subtitles.openFolderFromDrawer,
        ),
    ];
  }

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

  void _showWorksSortDialog() {
    final state = ref.read(worksProvider);
    showDialog(
      context: context,
      builder: (context) => SortOptionsDialog<SortOrder>(
        currentOption: state.sortOption,
        currentDirection: state.sortDirection,
        currentAgeRating: state.asmrOneAgeRating,
        availableOptions: SortOrder.values
            .where(
              (option) =>
                  option != SortOrder.updatedAt && option != SortOrder.nsfw,
            )
            .toList(),
        labelBuilder: (option) => option.localizedLabel(context),
        availableAgeRatings:
            ServerUtils.isOfficialServer(ref.read(authProvider).host)
            ? AgeRating.values
            : const [AgeRating.all, AgeRating.general, AgeRating.adult],
        onSort: (option, direction, ageRating) => ref
            .read(worksProvider.notifier)
            .applyWorksSort(option, direction, ageRating),
        confirmChanges: true,
      ),
    );
  }

  Future<void> _showJapaneseAsmrAgeRatingDialog() async {
    final rating = await showDialog<AgeRating>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(S.of(context).ageRatingLabel),
        children: [
          for (final value in const [AgeRating.all, AgeRating.general])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, value),
              child: Text(value.localizedLabel(context)),
            ),
        ],
      ),
    );
    if (rating == null || !mounted) return;
    ref.read(worksProvider.notifier).setJapaneseAsmrAgeRating(rating);
  }

  Future<void> _showClearHistoryConfirmation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.of(context).clearHistoryTitle),
        content: Text(S.of(context).clearHistoryConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.of(context).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.of(context).clear),
          ),
        ],
      ),
    );
    if (confirmed == true) await ref.read(historyProvider.notifier).clear();
  }

  Widget _buildOnlineBookmarksPage() {
    if (ref.watch(authProvider).isAnonymous) return const AudioAccountPrompt();
    final state = ref.watch(myReviewsProvider);
    return _buildBody(state);
  }

  Widget _buildBody(MyReviewsState state) {
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

    final layoutType = ref.watch(audioLayoutProvider);

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
        pageSize: layoutType == LayoutType.list
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
      padding: layoutType == LayoutType.list
          ? const EdgeInsets.fromLTRB(8, 8, 8, 8)
          : MediaQuery.orientationOf(context) == Orientation.landscape
          ? const EdgeInsets.fromLTRB(24, 8, 24, 24)
          : const EdgeInsets.fromLTRB(8, 8, 8, 8),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen<DisplayMode>(
      worksProvider.select((state) => state.displayMode),
      (previous, next) {
        if (previous == null ||
            previous == next ||
            _changingDisplayMode ||
            !_worksPageAtRest) {
          return;
        }
        final pageId = _pageForDisplayMode(next);
        final transition = _contentTransition.currentState;
        if (transition == null) {
          setState(() => _selectedPageId = pageId);
        } else {
          transition.animate(
            () => setState(() => _selectedPageId = pageId),
            reverse: next.index < previous.index,
          );
        }
      },
    );
    ref.listen<AudioSource>(audioSourceProvider, (previous, next) {
      if (previous != next && next == AudioSource.asmrOne) {
        unawaited(_loadMyReviewsIfNeeded());
      }
    });

    final settings = ref.watch(myTabsDisplayProvider);
    final source = ref.watch(audioSourceProvider);
    final authState = ref.watch(authProvider);
    final isOfficialServer = ServerUtils.isOfficialServer(authState.host);
    final displayMode = ref.watch(
      worksProvider.select((state) => state.displayMode),
    );
    final worksFailure = ref.watch(
      worksProvider.select(
        (state) => (error: state.error, isLoading: state.isLoading),
      ),
    );
    final marksState = ref.watch(myReviewsProvider);
    final activeDownloadCount =
        ref.watch(downloadSummaryProvider).valueOrNull?.active ?? 0;
    final tabs = _buildTabList(
      settings,
      source: source,
      isOfficialServer: isOfficialServer,
    );

    final selectedPhysical = _selectedPhysicalPage(_selectedPageId);
    var selectedIndex = tabs.indexWhere((tab) => tab.id == selectedPhysical);
    if (selectedIndex < 0) {
      selectedIndex = 0;
      _selectedPageId = _pageForDisplayMode(displayMode);
    }
    final tabIds = tabs.map((tab) => tab.id).toList(growable: false);
    if (!listEquals(_tabIds, tabIds)) {
      _pageTarget.value = null;
      _tabIds = tabIds;
      if (_pages.hasClients) _pages.jumpToPage(selectedIndex);
    }

    final title = _pageTitle(_selectedPageId);
    final searchHint = switch (_selectedPageId) {
      'home' || 'popular' || 'recommended' => S.of(context).searchOnlineWorks,
      _ => S.of(context).librarySearchHint(title),
    };
    return LibraryPageScaffold(
      topNotice: _buildSourceNotice(
        authState,
        source: source,
        worksError: worksFailure.error,
        worksLoading: worksFailure.isLoading,
      ),
      title: title,
      searchHint: searchHint,
      onSearch: _openAdvancedSearch,
      drawerFooter: LibraryDrawerTile(
        icon: Icons.settings_outlined,
        title: S.of(context).audioSettings,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const SettingsScreen(audioOnly: true),
          ),
        ),
      ),
      drawerChildren: _buildDrawerChildren(
        settings: settings,
        source: source,
        isAnonymous: authState.isAnonymous,
        isOfficialServer: isOfficialServer,
        displayMode: displayMode,
        marksState: marksState,
      ),
      floatingActionButton: _buildPageFab(activeDownloadCount, source: source),
      body: LibraryContentTransition(
        key: _contentTransition,
        child: TabPageWarmup(
          pages: _pages,
          target: _pageTarget,
          builder: (cacheExtent) => PageView.builder(
            key: const ValueKey('audio-tab-pages'),
            controller: _pages,
            physics: const NeverScrollableScrollPhysics(),
            allowImplicitScrolling: cacheExtent > 0,
            scrollCacheExtent: ScrollCacheExtent.viewport(cacheExtent),
            itemCount: tabs.length,
            findChildIndexCallback: (key) {
              final index = tabs.indexWhere((tab) => ValueKey(tab.id) == key);
              return index < 0 ? null : index;
            },
            itemBuilder: (context, index) => LazyTabPage(
              key: ValueKey(tabs[index].id),
              index: index,
              target: _pageTarget,
              pages: _pages,
              child: tabs[index].widget,
            ),
          ),
        ),
      ),
    );
  }

  Widget? _buildSourceNotice(
    AuthState auth, {
    required AudioSource source,
    required String? worksError,
    required bool worksLoading,
  }) {
    final offline =
        source == AudioSource.asmrOne &&
        auth.currentUser != null &&
        !auth.isLoggedIn &&
        auth.error != null;
    final retryingOffline =
        _retryingConnection &&
        source == AudioSource.asmrOne &&
        auth.currentUser != null;
    final sourceFailed =
        !offline && !retryingOffline && !worksLoading && worksError != null;
    if (!offline && !retryingOffline && !sourceFailed) {
      return null;
    }
    final navigation = AppNavigationScope.maybeOf(context);
    final visible =
        navigation == null ||
        (navigation.navigationVisible &&
            navigation.selectedIndex == appAudioTabIndex &&
            navigation.popupRoute == null);
    final s = S.of(context);
    final colors = Theme.of(context).colorScheme;
    final isOffline = offline || retryingOffline;
    final background = isOffline ? colors.secondaryContainer : colors.error;
    final foreground = isOffline ? colors.onSecondaryContainer : colors.onError;
    return Visibility(
      visible: visible,
      maintainState: true,
      maintainAnimation: true,
      maintainSize: true,
      child: SafeArea(
        top: false,
        bottom: false,
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: TopNoticeCard(
              backgroundColor: background,
              content: Row(
                children: [
                  Icon(
                    isOffline ? Icons.info_outline : Icons.error_outline,
                    color: foreground,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      isOffline ? s.offlineModeMessage : s.loadFailed,
                      style: TextStyle(color: foreground),
                    ),
                  ),
                ],
              ),
              action: SnackBarAction(
                label: s.retry,
                textColor: foreground,
                onPressed: isOffline
                    ? () async {
                        setState(() => _retryingConnection = true);
                        try {
                          await ref
                              .read(authProvider.notifier)
                              .retryConnection();
                        } finally {
                          if (mounted) {
                            setState(() => _retryingConnection = false);
                          }
                        }
                      }
                    : () =>
                          unawaited(ref.read(worksProvider.notifier).refresh()),
              ),
              actionEnabled: !isOffline || !_retryingConnection,
            ),
          ),
        ),
      ),
    );
  }

  Widget? _buildPageFab(
    int activeDownloadCount, {
    required AudioSource source,
  }) {
    if (_selectedPageId == 'home' ||
        _selectedPageId == 'popular' ||
        _selectedPageId == 'recommended' ||
        (_selectedPageId == 'onlineMarks' && source == AudioSource.asmrOne)) {
      return const DownloadFab();
    }
    if (_selectedPageId == 'downloads') {
      return Badge(
        isLabelVisible: activeDownloadCount > 0,
        label: Text('$activeDownloadCount'),
        child: FloatingActionButton(
          onPressed: _navigateToDownloads,
          tooltip: S.of(context).downloadTasks,
          child: const Icon(Icons.download),
        ),
      );
    }
    return null;
  }
}

class _TabInfo {
  const _TabInfo({
    required this.id,
    required this.title,
    required this.icon,
    required this.widget,
  });

  final String id;
  final String title;
  final IconData icon;
  final Widget widget;
}
