import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:equatable/equatable.dart';

import '../models/work.dart';
import '../models/audio_source.dart';
import '../models/japanese_asmr_browse.dart';
import '../models/search_type.dart';
import '../services/kikoeru_api_service.dart' hide kikoeruApiServiceProvider;
import '../services/log_service.dart';
import 'auth_provider.dart';
import 'settings_provider.dart';
import '../models/sort_options.dart';
import 'audio_source_provider.dart';
import '../utils/subtitle_filter.dart';
import '../utils/paged_collection.dart';
import '../utils/persistent_enum_preference.dart';

final _log = LogService.instance;

// Display mode - 展示模式
enum DisplayMode {
  all('all', '全部作品'),
  popular('popular', '热门推荐'),
  recommended('recommended', '推荐');

  const DisplayMode(this.value, this.label);
  final String value;
  final String label;
}

// Layout types - 参考原始代码的三种布局
enum LayoutType {
  list, // 列表布局
  smallGrid, // 小网格布局 (3列)
  bigGrid, // 大网格布局 (2列)
}

class WorksModeSnapshot extends Equatable {
  static const _noValue = Object();

  final List<Work> works;
  final List<Work> rawWorks;
  final bool isLoading;
  final bool isRefreshing;
  final bool isLoadingMore;
  final String? error;
  final String? loadMoreError;
  final int currentPage;
  final int totalCount;
  final bool hasMore;
  final bool isLastPage;

  const WorksModeSnapshot({
    this.works = const [],
    this.rawWorks = const [],
    this.isLoading = false,
    this.isRefreshing = false,
    this.isLoadingMore = false,
    this.error,
    this.loadMoreError,
    this.currentPage = 1,
    this.totalCount = 0,
    this.hasMore = true,
    this.isLastPage = false,
  });

  WorksModeSnapshot copyWith({
    List<Work>? works,
    List<Work>? rawWorks,
    bool? isLoading,
    bool? isRefreshing,
    bool? isLoadingMore,
    Object? error = _noValue,
    Object? loadMoreError = _noValue,
    int? currentPage,
    int? totalCount,
    bool? hasMore,
    bool? isLastPage,
  }) {
    return WorksModeSnapshot(
      works: works ?? this.works,
      rawWorks: rawWorks ?? this.rawWorks,
      isLoading: isLoading ?? this.isLoading,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: error == _noValue ? this.error : error as String?,
      loadMoreError: loadMoreError == _noValue
          ? this.loadMoreError
          : loadMoreError as String?,
      currentPage: currentPage ?? this.currentPage,
      totalCount: totalCount ?? this.totalCount,
      hasMore: hasMore ?? this.hasMore,
      isLastPage: isLastPage ?? this.isLastPage,
    );
  }

  @override
  List<Object?> get props => [
    works,
    rawWorks,
    isLoading,
    isRefreshing,
    isLoadingMore,
    error,
    loadMoreError,
    currentPage,
    totalCount,
    hasMore,
    isLastPage,
  ];
}

// Works state
class WorksState extends Equatable {
  static const _noArchiveDate = Object();

  final LayoutType layoutType;
  final SortOrder sortOption;
  final SortDirection sortDirection;
  final JapaneseAsmrSortOption japaneseAsmrSortOption;
  final SortDirection japaneseAsmrDirection;
  final AgeRating asmrOneAgeRating;
  final AgeRating japaneseAsmrAgeRating;
  final JapaneseAsmrPeriod japaneseAsmrCommentsPeriod;
  final JapaneseAsmrPeriod japaneseAsmrPopularPeriod;
  final DateTime? japaneseAsmrArchiveDate;
  final DisplayMode displayMode;
  final int subtitleFilter; // 0: 全部, 1: 有字幕
  final int basePageSize; // 用户设置的基础分页大小
  final Map<DisplayMode, WorksModeSnapshot> modeStates;

  int get pageSize => basePageSize;

  JapaneseAsmrPeriod get japaneseAsmrPeriod =>
      displayMode == DisplayMode.popular
      ? japaneseAsmrPopularPeriod
      : japaneseAsmrCommentsPeriod;

  WorksState({
    this.layoutType = LayoutType.bigGrid, // 默认大网格布局
    this.sortOption = SortOrder.release,
    this.sortDirection = SortDirection.desc,
    this.japaneseAsmrSortOption = JapaneseAsmrSortOption.date,
    this.japaneseAsmrDirection = SortDirection.desc,
    this.asmrOneAgeRating = AgeRating.all,
    this.japaneseAsmrAgeRating = AgeRating.all,
    this.japaneseAsmrCommentsPeriod = JapaneseAsmrPeriod.week,
    this.japaneseAsmrPopularPeriod = JapaneseAsmrPeriod.week,
    this.japaneseAsmrArchiveDate,
    this.displayMode = DisplayMode.all, // 默认显示全部作品
    this.subtitleFilter = 0, // 默认显示全部
    this.basePageSize = 40, // 全部模式每页40条
    Map<DisplayMode, WorksModeSnapshot>? modeStates,
  }) : modeStates = modeStates ?? _createInitialModeStates();

  WorksState copyWith({
    LayoutType? layoutType,
    SortOrder? sortOption,
    SortDirection? sortDirection,
    JapaneseAsmrSortOption? japaneseAsmrSortOption,
    SortDirection? japaneseAsmrDirection,
    AgeRating? asmrOneAgeRating,
    AgeRating? japaneseAsmrAgeRating,
    JapaneseAsmrPeriod? japaneseAsmrCommentsPeriod,
    JapaneseAsmrPeriod? japaneseAsmrPopularPeriod,
    Object? japaneseAsmrArchiveDate = _noArchiveDate,
    DisplayMode? displayMode,
    int? subtitleFilter,
    int? basePageSize,
    Map<DisplayMode, WorksModeSnapshot>? modeStates,
  }) {
    return WorksState(
      layoutType: layoutType ?? this.layoutType,
      sortOption: sortOption ?? this.sortOption,
      sortDirection: sortDirection ?? this.sortDirection,
      japaneseAsmrSortOption:
          japaneseAsmrSortOption ?? this.japaneseAsmrSortOption,
      japaneseAsmrDirection:
          japaneseAsmrDirection ?? this.japaneseAsmrDirection,
      asmrOneAgeRating: asmrOneAgeRating ?? this.asmrOneAgeRating,
      japaneseAsmrAgeRating:
          japaneseAsmrAgeRating ?? this.japaneseAsmrAgeRating,
      japaneseAsmrCommentsPeriod:
          japaneseAsmrCommentsPeriod ?? this.japaneseAsmrCommentsPeriod,
      japaneseAsmrPopularPeriod:
          japaneseAsmrPopularPeriod ?? this.japaneseAsmrPopularPeriod,
      japaneseAsmrArchiveDate:
          identical(japaneseAsmrArchiveDate, _noArchiveDate)
          ? this.japaneseAsmrArchiveDate
          : japaneseAsmrArchiveDate as DateTime?,
      displayMode: displayMode ?? this.displayMode,
      subtitleFilter: subtitleFilter ?? this.subtitleFilter,
      basePageSize: basePageSize ?? this.basePageSize,
      modeStates: modeStates ?? this.modeStates,
    );
  }

  WorksModeSnapshot get _currentModeState =>
      modeStates[displayMode] ?? const WorksModeSnapshot();

  List<Work> get works => _currentModeState.works;
  List<Work> get rawWorks => _currentModeState.rawWorks;
  bool get isLoading => _currentModeState.isLoading;
  bool get isRefreshing => _currentModeState.isRefreshing;
  bool get isLoadingMore => _currentModeState.isLoadingMore;
  String? get error => _currentModeState.error;
  String? get loadMoreError => _currentModeState.loadMoreError;
  int get currentPage => _currentModeState.currentPage;
  int get totalCount => _currentModeState.totalCount;
  bool get hasMore => _currentModeState.hasMore;
  bool get isLastPage => _currentModeState.isLastPage;

  static Map<DisplayMode, WorksModeSnapshot> _createInitialModeStates() {
    return {
      for (final mode in DisplayMode.values) mode: const WorksModeSnapshot(),
    };
  }

  @override
  List<Object?> get props => [
    layoutType,
    sortOption,
    sortDirection,
    japaneseAsmrSortOption,
    japaneseAsmrDirection,
    asmrOneAgeRating,
    japaneseAsmrAgeRating,
    japaneseAsmrCommentsPeriod,
    japaneseAsmrPopularPeriod,
    japaneseAsmrArchiveDate,
    displayMode,
    subtitleFilter,
    basePageSize,
    modeStates,
  ];
}

// Works notifier
class WorksNotifier extends StateNotifier<WorksState> {
  static const String layoutPreferenceKey = 'works_layout_type';

  final KikoeruApiService _apiService;
  final Ref _ref;
  final _layoutPreference = PersistentEnumPreference<LayoutType>(
    key: layoutPreferenceKey,
    values: LayoutType.values,
    fallback: LayoutType.bigGrid,
  );
  final Map<DisplayMode, PagedRequestGate> _requestGates = {
    for (final mode in DisplayMode.values) mode: PagedRequestGate(),
  };

  WorksNotifier(
    this._apiService,
    this._ref, {
    int initialPageSize = 40,
    SortOrder initialSortOption = SortOrder.release,
    SortDirection initialSortDirection = SortDirection.desc,
  }) : super(
         WorksState(
           basePageSize: initialPageSize,
           sortOption: _normalizedSortOption(initialSortOption),
           sortDirection: initialSortDirection,
           japaneseAsmrSortOption: initialSortOption == SortOrder.review
               ? JapaneseAsmrSortOption.comments
               : JapaneseAsmrSortOption.date,
           japaneseAsmrDirection:
               initialSortOption == SortOrder.release ||
                   initialSortOption == SortOrder.review
               ? initialSortDirection
               : SortDirection.desc,
           asmrOneAgeRating: initialSortOption == SortOrder.nsfw
               ? AgeRating.general
               : AgeRating.all,
         ),
       ) {
    _loadLayoutPreference();
  }

  Future<void> _loadLayoutPreference() async {
    final layoutType = await _layoutPreference.load();
    if (!mounted || layoutType == null || layoutType == state.layoutType) {
      return;
    }
    state = state.copyWith(layoutType: layoutType);
  }

  WorksModeSnapshot _getModeState(DisplayMode mode) {
    return state.modeStates[mode] ?? const WorksModeSnapshot();
  }

  void _updateModeState(
    DisplayMode mode,
    WorksModeSnapshot Function(WorksModeSnapshot current) updater,
  ) {
    final updatedStates = Map<DisplayMode, WorksModeSnapshot>.from(
      state.modeStates,
    );
    final currentSnapshot = _getModeState(mode);
    updatedStates[mode] = updater(currentSnapshot);
    state = state.copyWith(modeStates: updatedStates);
  }

  void _updateActiveModeState(
    WorksModeSnapshot Function(WorksModeSnapshot current) updater,
  ) {
    _updateModeState(state.displayMode, updater);
  }

  void updatePageSize(int newSize) {
    if (state.basePageSize == newSize) return;
    state = state.copyWith(basePageSize: newSize);
    loadWorks(targetPage: 1, supersede: true);
  }

  Future<void> loadWorks({
    bool refresh = false,
    int? targetPage,
    bool append = false,
    bool supersede = false,
  }) async {
    final mode = state.displayMode;
    final modeState = _getModeState(mode);
    final requestGate = _requestGates[mode]!;
    final requestToken = requestGate.begin(supersede: supersede);

    if (requestToken == null) {
      _log.captureOutput('[WorksProvider] Already loading, skipping');
      return;
    }

    final previousPage = modeState.currentPage;
    final isAllMode = mode == DisplayMode.all;
    final page =
        targetPage ??
        (isAllMode ? previousPage : (refresh ? 1 : previousPage + 1));
    final shouldAppend = !isAllMode && page > 1;

    _log.captureOutput(
      '[WorksProvider] Loading works - mode: $mode, page: $page, refresh: $refresh, currentPage: $previousPage, targetPage: $targetPage',
    );

    _updateModeState(
      mode,
      (snapshot) => snapshot.copyWith(
        isLoading: true,
        isRefreshing: !append,
        isLoadingMore: append,
        error: null,
        loadMoreError: null,
      ),
    );

    try {
      Map<String, dynamic> response;
      final source = _ref.read(audioSourceProvider);

      final pageSize = state.pageSize;
      final sortOption = state.sortOption;
      final sortDirection = state.sortDirection;

      final serverSubtitleParam = SubtitleFilterMode.fromValue(
        state.subtitleFilter,
      ).value;

      if (source == AudioSource.jpAsmr) {
        response = await _apiService.getWorks(
          page: page,
          pageSize: pageSize,
          source: source,
          japaneseAsmrSort: mode == DisplayMode.popular
              ? JapaneseAsmrSortOption.popular
              : state.japaneseAsmrSortOption,
          japaneseAsmrDirection: state.japaneseAsmrDirection,
          japaneseAsmrAgeRating: mode == DisplayMode.all
              ? state.japaneseAsmrAgeRating
              : AgeRating.all,
          japaneseAsmrPeriod: mode == DisplayMode.popular
              ? state.japaneseAsmrPopularPeriod
              : (state.japaneseAsmrSortOption == JapaneseAsmrSortOption.comments
                    ? state.japaneseAsmrCommentsPeriod
                    : JapaneseAsmrPeriod.week),
          japaneseAsmrArchiveYear:
              mode == DisplayMode.popular &&
                  state.japaneseAsmrArchiveDate != null
              ? state.japaneseAsmrArchiveDate!.year
              : null,
          japaneseAsmrArchiveMonth:
              mode == DisplayMode.popular &&
                  state.japaneseAsmrPopularPeriod ==
                      JapaneseAsmrPeriod.archiveMonth
              ? state.japaneseAsmrArchiveDate?.month
              : null,
          cancelToken: requestToken.cancelToken,
        );
      } else if (mode == DisplayMode.popular) {
        response = await _apiService.getPopularWorks(
          page: page,
          pageSize: pageSize,
          subtitle: serverSubtitleParam,
          cancelToken: requestToken.cancelToken,
        );
      } else if (mode == DisplayMode.recommended) {
        final currentUser = _ref.read(authProvider).currentUser;
        final recommenderUuid =
            currentUser?.recommenderUuid ??
            '766cc58d-7f1e-4958-9a93-913400f378dc';

        response = await _apiService.getRecommendedWorks(
          recommenderUuid: recommenderUuid,
          page: page,
          pageSize: pageSize,
          subtitle: serverSubtitleParam,
          cancelToken: requestToken.cancelToken,
        );
      } else if (mode == DisplayMode.all &&
          state.asmrOneAgeRating != AgeRating.all) {
        response = await _apiService.searchWorks(
          keyword: '\$age:${state.asmrOneAgeRating.value}\$',
          page: page,
          pageSize: pageSize,
          source: AudioSource.asmrOne,
          order: sortOption.value,
          sort: sortDirection.value,
          subtitle: serverSubtitleParam,
          cancelToken: requestToken.cancelToken,
        );
      } else {
        response = await _apiService.getWorks(
          page: page,
          source: source,
          order: sortOption.value,
          sort: sortDirection.value,
          subtitle: serverSubtitleParam,
          pageSize: pageSize,
          cancelToken: requestToken.cancelToken,
        );
      }

      final worksData = response['works'] as List<dynamic>?;
      final pagination = response['pagination'] as Map<String, dynamic>?;

      if (worksData == null) {
        throw Exception('No works data in response');
      }

      final works = worksData
          .map((workJson) => Work.fromJson(workJson as Map<String, dynamic>))
          .toList();

      if (!requestGate.isCurrent(requestToken)) return;

      final latestModeState = _getModeState(mode);
      final newRawWorks = mergePagedItems<Work, int>(
        existing: shouldAppend ? latestModeState.rawWorks : const [],
        incoming: works,
        idOf: (work) => work.id,
        replace: !shouldAppend,
      );

      final blockedItems = _ref.read(blockedItemsBySourceProvider(source));
      final filteredWorks = _filterWorks(newRawWorks, blockedItems);

      final totalCount = pagination?['totalCount'] as int? ?? 0;
      final currentPage = pagination?['currentPage'] as int? ?? page;

      bool hasMore;
      bool isLastPage = false;

      if (source == AudioSource.asmrOne &&
          (mode == DisplayMode.popular || mode == DisplayMode.recommended)) {
        final currentTotal = filteredWorks.length;
        hasMore =
            works.length >= pageSize &&
            currentTotal < 100 &&
            currentTotal < totalCount;
        isLastPage = !hasMore && filteredWorks.isNotEmpty;
      } else {
        hasMore = (currentPage * pageSize) < totalCount;
        isLastPage = !hasMore && filteredWorks.isNotEmpty;
      }

      _log.captureOutput(
        '[WorksProvider] Loaded ${filteredWorks.length} works (filtered from ${newRawWorks.length}), total: ${filteredWorks.length}, hasMore: $hasMore, currentPage: $currentPage',
      );

      _updateModeState(
        mode,
        (snapshot) => snapshot.copyWith(
          works: filteredWorks,
          rawWorks: newRawWorks,
          isLoading: false,
          isRefreshing: false,
          isLoadingMore: false,
          currentPage: currentPage,
          totalCount: totalCount,
          hasMore: hasMore,
          isLastPage: isLastPage,
          error: null,
          loadMoreError: null,
        ),
      );
    } catch (e) {
      if (!requestGate.isCurrent(requestToken)) return;
      _log.captureOutput('Failed to load works: $e');

      final message = '加载失败: ${e.toString()}';
      _updateModeState(
        mode,
        (snapshot) => snapshot.copyWith(
          isLoading: false,
          isRefreshing: false,
          isLoadingMore: false,
          error: append ? null : message,
          loadMoreError: append ? message : null,
        ),
      );
    } finally {
      requestGate.complete(requestToken);
    }
  }

  Future<void> refresh({bool resetPage = false}) async {
    await loadWorks(
      targetPage: resetPage ? 1 : state.currentPage,
      supersede: true,
    );
  }

  void onSourceChanged() {
    for (final gate in _requestGates.values) {
      gate.invalidate();
    }
    state = state.copyWith(
      displayMode: DisplayMode.all,
      modeStates: {
        for (final mode in DisplayMode.values) mode: const WorksModeSnapshot(),
      },
    );
    loadWorks(targetPage: 1, supersede: true);
  }

  Future<void> loadMore() async {
    final modeState = _getModeState(state.displayMode);
    if (modeState.isLoading || !modeState.hasMore) return;
    await loadWorks(targetPage: modeState.currentPage + 1, append: true);
  }

  // 跳转到指定页(仅全部模式)
  Future<void> goToPage(int page) async {
    if (state.displayMode != DisplayMode.all) return;
    if (page < 1) return;

    // 检查页码是否超出范围
    final maxPage = (state.totalCount / state.pageSize).ceil();
    if (page > maxPage && maxPage > 0) return;

    await loadWorks(targetPage: page);
  }

  // 下一页(仅全部模式)
  Future<void> nextPage() async {
    if (state.displayMode != DisplayMode.all) return;
    if (!state.hasMore || state.isLoading) return;
    await loadWorks(targetPage: state.currentPage + 1);
  }

  // 上一页(仅全部模式)
  Future<void> previousPage() async {
    if (state.displayMode != DisplayMode.all) return;
    if (state.currentPage <= 1 || state.isLoading) return;
    await loadWorks(targetPage: state.currentPage - 1);
  }

  void setSortOption(SortOrder option) {
    applyWorksSort(
      option,
      state.sortDirection,
      option == SortOrder.nsfw ? AgeRating.general : state.asmrOneAgeRating,
    );
  }

  void applyWorksSort(
    SortOrder option,
    SortDirection direction,
    AgeRating ageRating,
  ) {
    final normalizedOption = _normalizedSortOption(option);
    final normalizedAgeRating = option == SortOrder.nsfw
        ? AgeRating.general
        : ageRating;
    if (state.sortOption == normalizedOption &&
        state.sortDirection == direction &&
        state.asmrOneAgeRating == normalizedAgeRating) {
      return;
    }
    state = state.copyWith(
      sortOption: normalizedOption,
      sortDirection: direction,
      asmrOneAgeRating: normalizedAgeRating,
    );
    refresh(resetPage: true);
  }

  void applyDefaultSort(SortOrder option, SortDirection direction) {
    final normalizedOption = _normalizedSortOption(option);
    final ageRating = option == SortOrder.nsfw
        ? AgeRating.general
        : AgeRating.all;
    final japaneseAsmrSortOption = option == SortOrder.review
        ? JapaneseAsmrSortOption.comments
        : JapaneseAsmrSortOption.date;
    final japaneseAsmrDirection =
        option == SortOrder.release || option == SortOrder.review
        ? direction
        : SortDirection.desc;
    if (state.sortOption == normalizedOption &&
        state.sortDirection == direction &&
        state.asmrOneAgeRating == ageRating &&
        state.japaneseAsmrSortOption == japaneseAsmrSortOption &&
        state.japaneseAsmrDirection == japaneseAsmrDirection) {
      return;
    }
    for (final gate in _requestGates.values) {
      gate.invalidate();
    }
    state = state.copyWith(
      sortOption: normalizedOption,
      sortDirection: direction,
      asmrOneAgeRating: ageRating,
      japaneseAsmrSortOption: japaneseAsmrSortOption,
      japaneseAsmrDirection: japaneseAsmrDirection,
      modeStates: {
        for (final mode in DisplayMode.values) mode: const WorksModeSnapshot(),
      },
    );
    refresh(resetPage: true);
  }

  void setJapaneseAsmrSortOption(JapaneseAsmrSortOption option) {
    applyJapaneseAsmrSort(
      option,
      state.japaneseAsmrDirection,
      state.japaneseAsmrAgeRating,
    );
  }

  void applyJapaneseAsmrSort(
    JapaneseAsmrSortOption option,
    SortDirection direction,
    AgeRating ageRating,
  ) {
    if (state.japaneseAsmrSortOption == option &&
        state.japaneseAsmrDirection == direction &&
        state.japaneseAsmrAgeRating == ageRating) {
      return;
    }
    state = state.copyWith(
      japaneseAsmrSortOption: option,
      japaneseAsmrDirection: direction,
      japaneseAsmrAgeRating: ageRating,
    );
    refresh(resetPage: true);
  }

  void setJapaneseAsmrPeriod(
    JapaneseAsmrPeriod period, {
    DateTime? archiveDate,
  }) {
    final isPopular = state.displayMode == DisplayMode.popular;
    if (state.japaneseAsmrPeriod == period &&
        (!isPopular || state.japaneseAsmrArchiveDate == archiveDate)) {
      return;
    }
    state = state.copyWith(
      japaneseAsmrPopularPeriod: isPopular ? period : null,
      japaneseAsmrCommentsPeriod: isPopular ? null : period,
      japaneseAsmrArchiveDate: isPopular
          ? archiveDate
          : state.japaneseAsmrArchiveDate,
    );
    refresh(resetPage: true);
  }

  void setJapaneseAsmrSortDirection(SortDirection direction) {
    applyJapaneseAsmrSort(
      state.japaneseAsmrSortOption,
      direction,
      state.japaneseAsmrAgeRating,
    );
  }

  void setJapaneseAsmrAgeRating(AgeRating rating) {
    applyJapaneseAsmrSort(
      state.japaneseAsmrSortOption,
      state.japaneseAsmrDirection,
      rating,
    );
  }

  void setSortDirection(SortDirection direction) {
    applyWorksSort(state.sortOption, direction, state.asmrOneAgeRating);
  }

  void toggleSortDirection() {
    final newDirection = state.sortDirection == SortDirection.asc
        ? SortDirection.desc
        : SortDirection.asc;
    setSortDirection(newDirection);
  }

  void setLayoutType(LayoutType layoutType) {
    if (state.layoutType == layoutType) return;
    state = state.copyWith(layoutType: layoutType);
    unawaited(_layoutPreference.save(layoutType));
  }

  void toggleLayoutType() {
    late LayoutType newLayoutType;
    switch (state.layoutType) {
      case LayoutType.bigGrid:
        newLayoutType = LayoutType.smallGrid;
        break;
      case LayoutType.smallGrid:
        newLayoutType = LayoutType.list;
        break;
      case LayoutType.list:
        newLayoutType = LayoutType.bigGrid;
        break;
    }
    setLayoutType(newLayoutType);
  }

  void clearError() {
    _updateActiveModeState((modeState) => modeState.copyWith(error: null));
  }

  // Switch between all works and popular works
  void setDisplayMode(DisplayMode mode) {
    if (_ref.read(audioSourceProvider) == AudioSource.jpAsmr &&
        mode == DisplayMode.recommended) {
      mode = DisplayMode.all;
    }
    if (state.displayMode == mode) return;

    state = state.copyWith(displayMode: mode);

    final targetState = _getModeState(mode);
    final shouldLoadInitial =
        targetState.works.isEmpty && !targetState.isLoading;

    if (shouldLoadInitial) {
      refresh(resetPage: true);
    }
  }

  bool get isSubtitleFilterActive =>
      SubtitleFilterMode.fromValue(state.subtitleFilter).isActive;

  // Cycle subtitle filter: all -> with subtitles -> all
  void toggleSubtitleFilter() {
    final currentMode = SubtitleFilterMode.fromValue(state.subtitleFilter);
    setSubtitleFilter(currentMode.next);
  }

  void setSubtitleFilter(SubtitleFilterMode newFilterMode) {
    if (_ref.read(audioSourceProvider) == AudioSource.jpAsmr) return;
    final oldFilterMode = SubtitleFilterMode.fromValue(state.subtitleFilter);
    if (oldFilterMode == newFilterMode) return;
    for (final gate in _requestGates.values) {
      gate.invalidate();
    }
    state = state.copyWith(
      subtitleFilter: newFilterMode.value,
      modeStates: {
        for (final mode in DisplayMode.values) mode: const WorksModeSnapshot(),
      },
    );
    loadWorks(targetPage: 1, supersede: true);
  }

  void reapplyFilters() {
    final source = _ref.read(audioSourceProvider);
    final blockedItems = _ref.read(blockedItemsBySourceProvider(source));
    final updatedStates = state.modeStates.map((mode, snapshot) {
      final filteredWorks = _filterWorks(snapshot.rawWorks, blockedItems);
      return MapEntry(mode, snapshot.copyWith(works: filteredWorks));
    });
    state = state.copyWith(modeStates: updatedStates);
  }

  void onCurrentUserChanged() {
    if (!_apiService.isOfficialServer &&
        state.asmrOneAgeRating == AgeRating.r15) {
      _requestGates[DisplayMode.all]!.invalidate();
      final modeStates = Map<DisplayMode, WorksModeSnapshot>.from(
        state.modeStates,
      )..[DisplayMode.all] = const WorksModeSnapshot();
      state = state.copyWith(
        asmrOneAgeRating: AgeRating.all,
        modeStates: modeStates,
      );
      refresh(resetPage: true);
      return;
    }
    refresh();
  }

  List<Work> _filterWorks(List<Work> works, BlockedItemsState blockedItems) {
    return works.where((work) {
      // Check tags
      if (work.tags != null) {
        for (final tag in work.tags!) {
          if (blockedItems.tags.contains(tag.name)) return false;
        }
      }
      // Check CVs
      if (work.vas != null) {
        for (final va in work.vas!) {
          if (blockedItems.cvs.contains(va.name)) return false;
        }
      }
      // Check Circle
      if (work.name != null && blockedItems.circles.contains(work.name)) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  void dispose() {
    for (final gate in _requestGates.values) {
      gate.invalidate();
    }
    super.dispose();
  }
}

SortOrder _normalizedSortOption(SortOrder option) =>
    option == SortOrder.nsfw ? SortOrder.release : option;

// Provider
final worksProvider = StateNotifierProvider<WorksNotifier, WorksState>((ref) {
  final apiService = ref.watch(kikoeruApiServiceProvider);
  final pageSize = ref.read(pageSizeProvider);
  final defaultSort = ref.read(defaultSortProvider);

  final notifier = WorksNotifier(
    apiService,
    ref,
    initialPageSize: pageSize,
    initialSortOption: defaultSort.order,
    initialSortDirection: defaultSort.direction,
  );

  ref.listen(pageSizeProvider, (previous, next) {
    if (previous != next) {
      notifier.updatePageSize(next);
    }
  });

  ref.listen(audioSourceProvider, (previous, next) {
    if (previous != next) notifier.onSourceChanged();
  });

  ref.listen(defaultSortProvider, (previous, next) {
    if (previous?.order != next.order ||
        previous?.direction != next.direction) {
      notifier.applyDefaultSort(next.order, next.direction);
    }
  });

  // 监听用户切换，自动刷新作品列表
  ref.listen(currentUserProvider, (previous, next) {
    // 只有当用户真正变化时才刷新（用户名或服务器地址不同）
    final prevUser = previous;
    final nextUser = next;
    if (prevUser?.name != nextUser?.name || prevUser?.host != nextUser?.host) {
      _log.captureOutput('[WorksProvider] User changed, refreshing works list');
      notifier.onCurrentUserChanged();
    }
  });

  // 监听屏蔽列表变化，重新过滤
  ref.listen(blockedItemsBySourceProvider(AudioSource.asmrOne), (
    previous,
    next,
  ) {
    if (previous != next &&
        ref.read(audioSourceProvider) == AudioSource.asmrOne) {
      notifier.reapplyFilters();
    }
  });

  ref.listen(blockedItemsBySourceProvider(AudioSource.jpAsmr), (
    previous,
    next,
  ) {
    if (previous != next) {
      if (ref.read(audioSourceProvider) == AudioSource.jpAsmr) {
        notifier.reapplyFilters();
      }
    }
  });

  return notifier;
});
