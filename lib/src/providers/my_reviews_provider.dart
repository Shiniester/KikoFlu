import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:equatable/equatable.dart';

import '../models/work.dart';
import '../models/sort_options.dart';
import '../services/kikoeru_api_service.dart' hide kikoeruApiServiceProvider;
import '../services/log_service.dart';
import 'auth_provider.dart';
import 'settings_provider.dart';
import '../utils/subtitle_filter.dart';
import '../utils/paged_collection.dart';
import '../utils/persistent_enum_preference.dart';

/// 用户 Review/收藏状态的过滤枚举
enum MyReviewFilter {
  all(null, '全部'),
  marked('marked', '想听'),
  listening('listening', '在听'),
  listened('listened', '听过'),
  replay('replay', '重听'),
  postponed('postponed', '搁置');

  final String? value;
  final String label;
  const MyReviewFilter(this.value, this.label);
}

/// 布局类型枚举
enum MyReviewLayoutType {
  bigGrid, // 大网格（2列）
  smallGrid, // 小网格（3列）
  list, // 列表视图
}

class MyReviewsState extends Equatable {
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
  final MyReviewFilter filter;
  final int pageSize;
  final MyReviewLayoutType layoutType;
  final SortOrder sortType;
  final SortDirection sortOrder;
  final int subtitleFilter; // 0: 全部, 1: 有字幕

  int get effectivePageSize => pageSize;

  const MyReviewsState({
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
    this.filter = MyReviewFilter.all,
    this.pageSize = 20,
    this.layoutType = MyReviewLayoutType.bigGrid,
    this.sortType = SortOrder.updatedAt,
    this.sortOrder = SortDirection.desc,
    this.subtitleFilter = 0,
  });

  MyReviewsState copyWith({
    List<Work>? works,
    List<Work>? rawWorks,
    bool? isLoading,
    bool? isRefreshing,
    bool? isLoadingMore,
    String? error,
    String? loadMoreError,
    int? currentPage,
    int? totalCount,
    bool? hasMore,
    MyReviewFilter? filter,
    int? pageSize,
    MyReviewLayoutType? layoutType,
    SortOrder? sortType,
    SortDirection? sortOrder,
    int? subtitleFilter,
  }) {
    return MyReviewsState(
      works: works ?? this.works,
      rawWorks: rawWorks ?? this.rawWorks,
      isLoading: isLoading ?? this.isLoading,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: error,
      loadMoreError: loadMoreError,
      currentPage: currentPage ?? this.currentPage,
      totalCount: totalCount ?? this.totalCount,
      hasMore: hasMore ?? this.hasMore,
      filter: filter ?? this.filter,
      pageSize: pageSize ?? this.pageSize,
      layoutType: layoutType ?? this.layoutType,
      sortType: sortType ?? this.sortType,
      sortOrder: sortOrder ?? this.sortOrder,
      subtitleFilter: subtitleFilter ?? this.subtitleFilter,
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
    filter,
    pageSize,
    layoutType,
    sortType,
    sortOrder,
    subtitleFilter,
  ];
}

class MyReviewsNotifier extends StateNotifier<MyReviewsState> {
  static const String layoutPreferenceKey = 'my_reviews_layout_type';
  static const String filterPreferenceKey = 'my_reviews_filter';

  final KikoeruApiService _apiService;
  final PagedRequestGate _requestGate = PagedRequestGate();
  List<Work>? _subtitledWorks;
  final _layoutPreference = PersistentEnumPreference<MyReviewLayoutType>(
    key: layoutPreferenceKey,
    values: MyReviewLayoutType.values,
    fallback: MyReviewLayoutType.bigGrid,
  );
  final _filterPreference = PersistentEnumPreference<MyReviewFilter>(
    key: filterPreferenceKey,
    values: MyReviewFilter.values,
    fallback: MyReviewFilter.all,
  );
  late final Future<void> preferencesReady;

  MyReviewsNotifier(this._apiService, Ref ref, {int initialPageSize = 20})
    : super(MyReviewsState(pageSize: initialPageSize)) {
    preferencesReady = _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    await Future.wait([_loadLayoutPreference(), _loadFilterPreference()]);
  }

  Future<void> _loadLayoutPreference() async {
    final layoutType = await _layoutPreference.load();
    if (!mounted || layoutType == null) return;

    state = state.copyWith(
      layoutType: layoutType,
      error: state.error,
      loadMoreError: state.loadMoreError,
    );
  }

  Future<void> _loadFilterPreference() async {
    final filter = await _filterPreference.load();
    if (!mounted || filter == null) return;

    state = state.copyWith(
      filter: filter,
      error: state.error,
      loadMoreError: state.loadMoreError,
    );
  }

  void updatePageSize(int newSize) {
    if (state.pageSize == newSize) return;
    state = state.copyWith(pageSize: newSize);
    load(targetPage: 1, supersede: true);
  }

  Future<void> load({
    bool refresh = false,
    int? targetPage,
    bool append = false,
    bool supersede = false,
  }) async {
    await preferencesReady;
    if (!mounted) return;

    final requestToken = _requestGate.begin(supersede: supersede || refresh);
    if (requestToken == null) return;
    if (refresh) _subtitledWorks = null;
    final page = targetPage ?? state.currentPage;

    state = state.copyWith(
      isLoading: true,
      isRefreshing: !append,
      isLoadingMore: append,
      error: null,
      loadMoreError: null,
    );

    try {
      final subtitleFilter = state.subtitleFilter;
      final filterSubtitles = SubtitleFilterMode.fromValue(
        subtitleFilter,
      ).isActive;
      final pageSize = state.effectivePageSize;
      var rawWorks = _subtitledWorks ?? const <Work>[];
      var totalCount = 0;
      if (!filterSubtitles || _subtitledWorks == null) {
        final works = <Work>[];
        var requestPage = filterSubtitles ? 1 : page;
        final filter = state.filter.value;
        final order = state.sortType.value;
        final sort = state.sortOrder.value;
        var receivedCount = 0;
        // /api/review has no subtitle query; filter the complete mark collection.
        do {
          final result = await _apiService.getMyReviews(
            page: requestPage,
            pageSize: pageSize,
            filter: filter,
            order: order,
            sort: sort,
            cancelToken: requestToken.cancelToken,
          );
          if (!_requestGate.isCurrent(requestToken)) return;
          final rawList =
              (result['works'] as List?) ??
              (result['reviews'] as List?) ??
              (result['data'] as List?) ??
              [];
          receivedCount = rawList.length;
          works.addAll(
            rawList.map((item) {
              if (item is Map<String, dynamic>) {
                final workJson = item.containsKey('work')
                    ? item['work'] as Map<String, dynamic>
                    : item;
                return Work.fromJson(workJson);
              }
              throw Exception('Unexpected review item format');
            }),
          );
          final pagination = result['pagination'] as Map<String, dynamic>?;
          totalCount = pagination?['totalCount'] as int? ?? 0;
          requestPage++;
        } while (filterSubtitles &&
            receivedCount > 0 &&
            (requestPage - 1) * pageSize < totalCount);

        rawWorks = mergePagedItems<Work, int>(
          existing: const [],
          incoming: works,
          idOf: (work) => work.id,
          replace: true,
        );
        if (filterSubtitles) {
          rawWorks = filterWorksBySubtitleMode(rawWorks, subtitleFilter);
          _subtitledWorks = rawWorks;
        }
      }
      if (filterSubtitles) totalCount = rawWorks.length;

      // 计算是否有更多页
      final totalPages = totalCount > 0 ? (totalCount / pageSize).ceil() : 1;
      final currentPage = filterSubtitles ? page.clamp(1, totalPages) : page;
      if (filterSubtitles) {
        rawWorks = rawWorks
            .skip((currentPage - 1) * pageSize)
            .take(pageSize)
            .toList();
      }
      final hasMore = currentPage < totalPages;

      state = state.copyWith(
        works: rawWorks,
        rawWorks: rawWorks,
        totalCount: totalCount,
        hasMore: hasMore,
        isLoading: false,
        isRefreshing: false,
        isLoadingMore: false,
        currentPage: currentPage,
        error: null,
        loadMoreError: null,
      );
    } catch (e) {
      if (!_requestGate.isCurrent(requestToken)) return;
      final message = e.toString();
      state = state.copyWith(
        isLoading: false,
        isRefreshing: false,
        isLoadingMore: false,
        error: append ? null : message,
        loadMoreError: append ? message : null,
      );
    } finally {
      _requestGate.complete(requestToken);
    }
  }

  // 跳转到指定页
  Future<void> goToPage(int page) async {
    if (page < 1 || state.isLoading) return;
    await load(targetPage: page);
  }

  // 上一页
  Future<void> previousPage() async {
    if (state.currentPage > 1) {
      final prevPage = state.currentPage - 1;
      await load(targetPage: prevPage);
    }
  }

  // 下一页
  Future<void> nextPage() async {
    if (state.isLoading || !state.hasMore) return;
    await load(targetPage: state.currentPage + 1);
  }

  Future<void> loadMore() async {
    if (state.isLoading || !state.hasMore) return;
    await load(targetPage: state.currentPage + 1);
  }

  void changeFilter(MyReviewFilter filter) {
    if (state.filter == filter) return;
    _subtitledWorks = null;
    state = state.copyWith(filter: filter, currentPage: 1, totalCount: 0);
    unawaited(_filterPreference.save(filter));
    load(targetPage: 1, supersede: true);
  }

  bool get isSubtitleFilterActive =>
      SubtitleFilterMode.fromValue(state.subtitleFilter).isActive;

  void toggleSubtitleFilter() {
    final currentMode = SubtitleFilterMode.fromValue(state.subtitleFilter);
    setSubtitleFilter(currentMode.next);
  }

  void setSubtitleFilter(SubtitleFilterMode newFilterMode) {
    final oldFilterMode = SubtitleFilterMode.fromValue(state.subtitleFilter);
    if (oldFilterMode == newFilterMode) return;
    _subtitledWorks = null;
    state = state.copyWith(
      subtitleFilter: newFilterMode.value,
      works: const [],
      rawWorks: const [],
      currentPage: 1,
      totalCount: 0,
    );
    load(targetPage: 1, supersede: true);
  }

  void changeSort(SortOrder sortType, SortDirection sortOrder) {
    if (state.sortType == sortType && state.sortOrder == sortOrder) return;
    _subtitledWorks = null;
    state = state.copyWith(
      sortType: sortType,
      sortOrder: sortOrder,
      currentPage: 1,
      totalCount: 0,
    );
    load(targetPage: 1, supersede: true);
  }

  // 切换布局类型
  void toggleLayoutType() {
    final nextLayout = switch (state.layoutType) {
      MyReviewLayoutType.bigGrid => MyReviewLayoutType.smallGrid,
      MyReviewLayoutType.smallGrid => MyReviewLayoutType.list,
      MyReviewLayoutType.list => MyReviewLayoutType.bigGrid,
    };
    setLayoutType(nextLayout);
  }

  void setLayoutType(MyReviewLayoutType layoutType) {
    if (state.layoutType == layoutType) return;
    state = state.copyWith(layoutType: layoutType);
    unawaited(_layoutPreference.save(layoutType));
  }

  Future<void> refresh() =>
      load(refresh: true, targetPage: state.currentPage, supersede: true);

  @override
  void dispose() {
    _requestGate.invalidate();
    super.dispose();
  }
}

final myReviewsProvider =
    StateNotifierProvider<MyReviewsNotifier, MyReviewsState>((ref) {
      final apiService = ref.watch(kikoeruApiServiceProvider);
      final pageSize = ref.read(pageSizeProvider);
      final notifier = MyReviewsNotifier(
        apiService,
        ref,
        initialPageSize: pageSize,
      );

      ref.listen(pageSizeProvider, (previous, next) {
        if (previous != next) {
          notifier.updatePageSize(next);
        }
      });

      // 监听用户切换，自动刷新我的评价/收藏列表
      ref.listen(currentUserProvider, (previous, next) {
        final prevUser = previous;
        final nextUser = next;
        if (prevUser?.name != nextUser?.name ||
            prevUser?.host != nextUser?.host) {
          logOutput('[MyReviewsProvider] User changed, refreshing my reviews');
          notifier.refresh();
        }
      });

      return notifier;
    });
