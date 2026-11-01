import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';

import '../../l10n/app_localizations.dart';
import '../models/audio_source.dart';
import '../models/search_type.dart';
import '../models/search_query.dart';
import '../models/search_scope_session.dart';
import '../models/sort_options.dart';
import '../providers/auth_provider.dart';
import '../providers/audio_source_provider.dart';
import '../providers/my_reviews_provider.dart';
import '../providers/unified_search_history_provider.dart';
import '../utils/l10n_extensions.dart';
import '../utils/server_utils.dart';
import '../utils/snackbar_util.dart';
import '../utils/tag_localizer.dart';
import '../utils/ui_tokens.dart';
import '../services/log_service.dart';
import '../widgets/scrollable_appbar.dart';
import '../widgets/download_fab.dart';
import '../widgets/floating_feed_toolbar.dart';
import '../widgets/material_popup_surface.dart';
import '../widgets/search_condition_chip.dart';
import '../widgets/search_filter_panel.dart';
import '../widgets/search_history_section.dart';
import '../widgets/search_input_decoration.dart';
import '../widgets/japanese_asmr_access_prompt.dart';
import 'search_result_screen.dart';
import 'scoped_search_result_screen.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({
    super.key,
    this.showBackButton = false,
    this.scope,
    this.progressFilter,
    this.initialKeyword,
    this.initialSearchParams,
    this.initialSortOption,
    this.initialSortDirection,
    this.initialSubtitleFilter = 0,
  });

  final bool showBackButton;
  final SearchScope? scope;
  final String? progressFilter;
  final String? initialKeyword;
  final Map<String, dynamic>? initialSearchParams;
  final SortOrder? initialSortOption;
  final SortDirection? initialSortDirection;
  final int initialSubtitleFilter;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  late final AnimationController _conditionsReveal;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _filterPanelKey = GlobalKey<SearchFilterPanelState>();
  final _conditionsScrollController = ScrollController(); // 用于搜索条件横向滚动
  final List<SearchCondition> _searchConditions = [];
  final SearchScopeSession _scopeSession = SearchScopeSession();
  late final UnifiedSearchHistorySession _historySession;
  Key _autocompleteKey = UniqueKey(); // 用于强制刷新 Autocomplete
  String _activeKeyword = '';
  Map<String, dynamic>? _activeSearchParams;
  SearchQuery? _activeScopedQuery;
  SortOrder _activeSortOption = SortOrder.release;
  SortDirection _activeSortDirection = SortDirection.desc;
  int _activeSubtitleFilter = 0;
  int _searchRevision = 0;
  bool _hasSubmittedSearch = false;
  bool _didRestoreInitialQuery = false;
  bool _submitAfterSuggestion = false;

  SearchType _currentSearchType = SearchType.keyword;
  bool _isExcludeMode = false; // 是否处于反选（排除）模式
  double _minRate = 0;
  AgeRating _ageRating = AgeRating.all;
  SalesRange _salesRange = SalesRange.all;

  // 建议列表数据（使用原始 JSON 以保留 count 字段）
  List<Map<String, dynamic>> _allTags = [];
  List<Map<String, dynamic>> _allVas = [];
  List<Map<String, dynamic>> _allCircles = [];
  final Map<SearchType, List<Map<String, dynamic>>> _japaneseCatalogs = {};
  bool _isLoadingSuggestions = false;
  String? _suggestionError;
  CancelToken? _suggestionCancelToken;
  int _suggestionRequestId = 0;

  @override
  bool get wantKeepAlive => true; // 保持状态不被销毁

  @override
  void initState() {
    super.initState();
    _historySession = UnifiedSearchHistorySession(
      ref.read(unifiedSearchHistoryProvider.notifier),
    );
    _activeSortOption = widget.initialSortOption ?? SortOrder.release;
    _activeSortDirection = widget.initialSortDirection ?? SortDirection.desc;
    _activeSubtitleFilter = widget.initialSubtitleFilter;
    _conditionsReveal = AnimationController(
      vsync: this,
      duration: UiMotion.reveal,
    );
    _loadSuggestions();
  }

  @override
  void dispose() {
    _conditionsReveal.dispose();
    _conditionsScrollController.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    _suggestionCancelToken?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didRestoreInitialQuery &&
        (widget.initialKeyword != null || widget.initialSearchParams != null)) {
      _didRestoreInitialQuery = true;
      _restoreQuery(
        keyword: widget.initialKeyword ?? '',
        searchParams: widget.initialSearchParams,
        sortOption: widget.initialSortOption,
        sortDirection: widget.initialSortDirection,
        subtitleFilter: widget.initialSubtitleFilter,
      );
      _updateConditionsReveal();
      _hasSubmittedSearch = true;
      _searchRevision++;
      _activeKeyword = widget.initialKeyword ?? '';
      _activeSearchParams = widget.initialSearchParams;
      if (widget.scope != null && widget.scope != SearchScope.globalWorks) {
        _activeScopedQuery = _buildScopedQuery(_searchConditions);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          _historySession.submit(
            _historyContext,
            _historyPayload(
              keyword: _activeKeyword,
              searchParams: _activeSearchParams ?? const {},
              conditions: _searchConditions,
            ),
          ),
        );
      });
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _conditionsReveal.value = _hasSelectedFilters ? 1 : 0;
    }
  }

  bool get _hasSelectedFilters =>
      _searchConditions.isNotEmpty ||
      _minRate > 0 ||
      _ageRating != AgeRating.all ||
      _salesRange != SalesRange.all;

  void _updateConditionsReveal() {
    final target = _hasSelectedFilters ? 1.0 : 0.0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _conditionsReveal.value = target;
    } else {
      _conditionsReveal.animateTo(
        target,
        duration: UiMotion.reveal,
        curve: UiMotion.curve,
      );
    }
  }

  // 加载建议数据
  Future<void> _loadSuggestions() async {
    final requestId = ++_suggestionRequestId;
    _suggestionCancelToken?.cancel();
    _suggestionCancelToken = null;
    final searchType = _currentSearchType;
    final isJapanese = _isJapaneseGlobalSearch;
    if (searchType == SearchType.keyword || searchType == SearchType.rjNumber) {
      _isLoadingSuggestions = false;
      _suggestionError = null;
      return; // 关键词和RJ号不需要建议列表
    }

    if (!mounted) return;
    final cancelToken = CancelToken();
    _suggestionCancelToken = cancelToken;
    setState(() {
      _isLoadingSuggestions = true;
      _suggestionError = null;
    });

    try {
      final api = ref.read(kikoeruApiServiceProvider);
      if (isJapanese) {
        if (!_japaneseCatalogs.containsKey(searchType)) {
          final data = await api.getSearchCatalog(
            searchType,
            cancelToken: cancelToken,
          );
          if (!mounted ||
              requestId != _suggestionRequestId ||
              _currentSearchType != searchType ||
              _isJapaneseGlobalSearch != isJapanese) {
            return;
          }
          _japaneseCatalogs[searchType] = data;
        }
      } else {
        switch (searchType) {
          case SearchType.tag:
            if (_allTags.isEmpty) {
              final data = await api.getAllTags(cancelToken: cancelToken);
              if (!_isCurrentSuggestionRequest(
                requestId,
                searchType,
                isJapanese,
              )) {
                return;
              }
              _allTags = List<Map<String, dynamic>>.from(data);
              _allTags.sort(
                (a, b) => (b['count'] ?? 0).compareTo(a['count'] ?? 0),
              );
            }
            break;
          case SearchType.va:
            if (_allVas.isEmpty) {
              final data = await api.getAllVas(cancelToken: cancelToken);
              if (!_isCurrentSuggestionRequest(
                requestId,
                searchType,
                isJapanese,
              )) {
                return;
              }
              _allVas = List<Map<String, dynamic>>.from(data);
              _allVas.sort(
                (a, b) => (b['count'] ?? 0).compareTo(a['count'] ?? 0),
              );
            }
            break;
          case SearchType.circle:
            if (_allCircles.isEmpty) {
              final data = await api.getAllCircles(cancelToken: cancelToken);
              if (!_isCurrentSuggestionRequest(
                requestId,
                searchType,
                isJapanese,
              )) {
                return;
              }
              _allCircles = List<Map<String, dynamic>>.from(data);
              _allCircles.sort(
                (a, b) => (b['count'] ?? 0).compareTo(a['count'] ?? 0),
              );
            }
            break;
          default:
            break;
        }
      }

      // 数据加载完成后刷新 Autocomplete
      if (!_isCurrentSuggestionRequest(requestId, searchType, isJapanese)) {
        return;
      }
      final restoreFocus = _searchFocusNode.hasFocus;
      setState(() {
        _autocompleteKey = UniqueKey();
      });
      if (restoreFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _searchFocusNode.requestFocus();
          final value = _searchController.value;
          final affinity = value.selection.affinity == TextAffinity.upstream
              ? TextAffinity.downstream
              : TextAffinity.upstream;
          _searchController.value = value.copyWith(
            selection: value.selection.copyWith(affinity: affinity),
          );
        });
      }
    } catch (e) {
      if (!mounted || requestId != _suggestionRequestId) return;
      logOutput('加载建议列表失败: $e');
      setState(() => _suggestionError = e.toString());
    } finally {
      if (mounted && requestId == _suggestionRequestId) {
        setState(() => _isLoadingSuggestions = false);
      }
    }
  }

  bool _isCurrentSuggestionRequest(
    int requestId,
    SearchType type,
    bool isJapanese,
  ) =>
      mounted &&
      requestId == _suggestionRequestId &&
      _currentSearchType == type &&
      _isJapaneseGlobalSearch == isJapanese;

  void _loadSuggestionsIfNeeded() {
    final type = _currentSearchType;
    if (_isLoadingSuggestions ||
        type == SearchType.keyword ||
        type == SearchType.rjNumber) {
      return;
    }
    final isJapanese = _isJapaneseGlobalSearch;
    final hasSuggestions = isJapanese
        ? _japaneseCatalogs.containsKey(type)
        : switch (type) {
            SearchType.tag => _allTags.isNotEmpty,
            SearchType.va => _allVas.isNotEmpty,
            SearchType.circle => _allCircles.isNotEmpty,
            SearchType.keyword || SearchType.rjNumber => true,
          };
    if (!hasSuggestions) unawaited(_loadSuggestions());
  }

  bool get _isJapaneseGlobalSearch =>
      (widget.scope == null || widget.scope == SearchScope.globalWorks) &&
      ref.read(audioSourceProvider) == AudioSource.jpAsmr;

  List<_SearchSuggestion> _searchSuggestions(String query) {
    final isJapanese = _isJapaneseGlobalSearch;
    final source = isJapanese
        ? _japaneseCatalogs[_currentSearchType] ?? const []
        : switch (_currentSearchType) {
            SearchType.tag => _allTags,
            SearchType.va => _allVas,
            SearchType.circle => _allCircles,
            _ => const <Map<String, dynamic>>[],
          };
    final normalizedQuery = query.trim().toLowerCase();
    return [
      for (final item in source)
        if (item['name'] != null || item['title'] != null)
          _suggestionFromItem(item, isJapanese),
    ].where((suggestion) {
      if (normalizedQuery.isEmpty ||
          suggestion.name.toLowerCase().contains(normalizedQuery)) {
        return true;
      }
      return !isJapanese &&
          _currentSearchType == SearchType.tag &&
          suggestion.localizedName.toLowerCase().contains(normalizedQuery);
    }).toList();
  }

  _SearchSuggestion _suggestionFromItem(
    Map<String, dynamic> item,
    bool isJapanese,
  ) {
    final name = (item['name'] ?? item['title']).toString();
    final id = item['id'];
    final localizedName =
        !isJapanese && _currentSearchType == SearchType.tag && id is int
        ? TagLocalizer.localize(id, name, Localizations.localeOf(context))
        : name;
    final count = item['count'];
    return _SearchSuggestion(
      name: name,
      value: isJapanese ? name : localizedName,
      localizedName: localizedName,
      count: count is num ? count.toInt() : 0,
      sourcePath: isJapanese ? item['sourcePath'] as String? : null,
    );
  }

  void _addSearchCondition({
    _SearchSuggestion? suggestion,
    bool submit = false,
  }) {
    final isDirectoryType =
        _currentSearchType == SearchType.tag ||
        _currentSearchType == SearchType.va ||
        _currentSearchType == SearchType.circle;
    if (suggestion == null && _isJapaneseGlobalSearch && isDirectoryType) {
      return;
    }
    final value = suggestion?.value ?? _searchController.text.trim();
    if (value.isEmpty) {
      SnackBarUtil.showWarning(context, S.of(context).enterSearchContent);
      return;
    }

    final wasEmpty = _searchConditions.isEmpty;
    final condition = SearchCondition(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: _currentSearchType,
      value: value,
      isExclude: _isExcludeMode,
      sourcePath: suggestion?.sourcePath,
    );
    final conditions = [..._searchConditions, condition];
    setState(() {
      _searchConditions.add(condition);
      _searchController.clear();
      _autocompleteKey = UniqueKey();
      // 添加后重置为正选模式
      _isExcludeMode = false;
    });

    if (wasEmpty) _updateConditionsReveal();
    // 取消焦点，关闭下拉框
    FocusScope.of(context).unfocus();

    // 自动滚动到最新添加的标签位置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _conditionsScrollController.hasClients) {
        final target = _conditionsScrollController.position.maxScrollExtent;
        if (MediaQuery.disableAnimationsOf(context)) {
          _conditionsScrollController.jumpTo(target);
        } else {
          _conditionsScrollController.animateTo(
            target,
            duration: UiMotion.reveal,
            curve: Curves.easeOutCubic,
          );
        }
      }
    });
    if (submit || _hasSubmittedSearch) {
      _performSearch(conditions: conditions, manual: submit);
    }
  }

  void _removeSearchCondition(String id) {
    final conditions = _searchConditions
        .where((condition) => condition.id != id)
        .toList();
    setState(() {
      _searchConditions
        ..clear()
        ..addAll(conditions);
    });
    if (_searchConditions.isEmpty) _updateConditionsReveal();
    if (_hasSubmittedSearch) _performSearch(conditions: conditions);
  }

  Future<void> _performSearch({
    List<SearchCondition>? conditions,
    Map<String, dynamic>? searchParamsOverride,
    bool manual = false,
    bool includeInput = true,
    bool updateHistory = true,
    SortOrder? sortOption,
    SortDirection? sortDirection,
    int? subtitleFilter,
  }) async {
    if (manual) _filterPanelKey.currentState?.collapse();
    final nextSortOption = sortOption ?? _activeSortOption;
    final nextSortDirection = sortDirection ?? _activeSortDirection;
    final nextSubtitleFilter = subtitleFilter ?? _activeSubtitleFilter;
    final effectiveConditions = List<SearchCondition>.of(
      conditions ?? _searchConditions,
    );
    final input = includeInput ? _searchController.text.trim() : '';
    final isDirectoryType =
        _currentSearchType == SearchType.tag ||
        _currentSearchType == SearchType.va ||
        _currentSearchType == SearchType.circle;
    if (input.isNotEmpty && !(_isJapaneseGlobalSearch && isDirectoryType)) {
      effectiveConditions.add(
        SearchCondition(
          id: 'input-${DateTime.now().microsecondsSinceEpoch}',
          type: _currentSearchType,
          value: input,
          isExclude: _isExcludeMode,
        ),
      );
    }

    final hasAdvancedFilter =
        _minRate > 0 ||
        _ageRating != AgeRating.all ||
        _salesRange != SalesRange.all;
    if (effectiveConditions.isEmpty && !hasAdvancedFilter) {
      if (_hasSubmittedSearch && !manual) {
        setState(() {
          _hasSubmittedSearch = false;
          _activeKeyword = '';
          _activeSearchParams = null;
          _activeScopedQuery = null;
        });
        return;
      }
      SnackBarUtil.showWarning(
        context,
        S.of(context).addAtLeastOneSearchCondition,
      );
      return;
    }

    final searchKeyword = _searchKeyword(effectiveConditions);
    final searchParams = searchParamsOverride == null
        ? <String, dynamic>{
            'keyword': searchKeyword,
            'conditions': effectiveConditions.map(_conditionToJson).toList(),
            if (_isJapaneseGlobalSearch) 'source': AudioSource.jpAsmr.name,
            'minRate': _minRate,
            'ageRating': _ageRating.localizedLabel(context),
            'ageRatingValue': _ageRating.value,
            'salesRange': _salesRange.localizedLabel(context),
            'salesRangeValue': _salesRange.value,
          }
        : Map<String, dynamic>.from(searchParamsOverride);
    if (searchParamsOverride == null) {
      if (_minRate <= 0) searchParams.remove('minRate');
      if (_ageRating == AgeRating.all) {
        searchParams.remove('ageRating');
        searchParams.remove('ageRatingValue');
      }
      if (_salesRange == SalesRange.all) {
        searchParams.remove('salesRange');
        searchParams.remove('salesRangeValue');
      }
    }

    final displayParts = effectiveConditions.map((c) {
      final prefix = c.isExclude ? '${S.of(context).excludeMode} ' : '';
      final value = c.type == SearchType.rjNumber
          ? 'RJ${c.value}'
          : c.type == SearchType.tag
          ? TagLocalizer.localizeByName(
              c.value,
              Localizations.localeOf(context),
            )
          : c.value;
      return '$prefix${c.type.localizedLabel(context)}: $value';
    }).toList();
    final displayText = displayParts.join(', ');
    final payload = _historyPayload(
      keyword: searchKeyword,
      searchParams: searchParams,
      conditions: effectiveConditions,
      displayText: displayText,
      sortOption: nextSortOption,
      sortDirection: nextSortDirection,
      subtitleFilter: nextSubtitleFilter,
    );

    setState(() {
      _activeKeyword = searchKeyword;
      _activeSearchParams = searchParams;
      _activeSortOption = nextSortOption;
      _activeSortDirection = nextSortDirection;
      _activeSubtitleFilter = nextSubtitleFilter;
      _hasSubmittedSearch = true;
      _searchRevision++;
      if (widget.scope != null && widget.scope != SearchScope.globalWorks) {
        _activeScopedQuery = _buildScopedQuery(effectiveConditions);
      }
    });
    FocusScope.of(context).unfocus();

    if (manual) {
      unawaited(_historySession.submit(_historyContext, payload));
    } else if (updateHistory) {
      unawaited(_historySession.update(_historyContext, payload));
    }
  }

  String _searchKeyword(List<SearchCondition> conditions) {
    final parts = [
      for (final condition in conditions)
        if (condition.sourcePath == null) condition.toSearchString(),
      if (_minRate > 0) '\$rate:${_minRate.toInt()}\$',
      if (_ageRating != AgeRating.all && _ageRating.value.isNotEmpty)
        '\$age:${_ageRating.value}\$',
      if (_salesRange != SalesRange.all && _salesRange.value > 0)
        '\$sell:${_salesRange.value}\$',
    ];
    return parts.join(' ');
  }

  Map<String, dynamic> _conditionToJson(SearchCondition condition) => {
    'type': condition.type.localizedLabel(context),
    'searchType': condition.type.name,
    'value': condition.value,
    'isExclude': condition.isExclude,
    if (condition.sourcePath != null) 'sourcePath': condition.sourcePath,
  };

  SearchQuery _buildScopedQuery(List<SearchCondition> conditions) =>
      SearchQuery(
        scope: widget.scope!,
        conditions: conditions,
        minRate: _minRate,
        ageRating: _ageRating,
        salesRange: _salesRange,
        progressFilter: widget.progressFilter,
      );

  Map<String, Object?> _historyPayload({
    required String keyword,
    required Map<String, dynamic> searchParams,
    required List<SearchCondition> conditions,
    String? displayText,
    SortOrder? sortOption,
    SortDirection? sortDirection,
    int? subtitleFilter,
  }) {
    final labels =
        displayText ??
        conditions
            .map((condition) {
              final prefix = condition.isExclude
                  ? '${S.of(context).excludeMode} '
                  : '';
              final value = condition.type == SearchType.rjNumber
                  ? 'RJ${condition.value}'
                  : condition.type == SearchType.tag
                  ? TagLocalizer.localizeByName(
                      condition.value,
                      Localizations.localeOf(context),
                    )
                  : condition.value;
              return '$prefix${condition.type.localizedLabel(context)}: $value';
            })
            .join(', ');
    return {
      'keyword': keyword,
      'displayText': labels.isEmpty ? keyword : labels,
      'searchParams': searchParams,
      'conditions': conditions.map(_conditionToJson).toList(),
      if (_minRate > 0) 'minRate': _minRate,
      'ageRatingValue': _ageRating.value,
      'salesRangeValue': _salesRange.value,
      'sortOption': (sortOption ?? _activeSortOption).name,
      'sortDirection': (sortDirection ?? _activeSortDirection).name,
      'subtitleFilter': subtitleFilter ?? _activeSubtitleFilter,
    };
  }

  UnifiedSearchHistoryContext get _historyContext {
    final scope = widget.scope;
    var entryScope = 'global-works';
    if (scope != null && scope != SearchScope.globalWorks) {
      entryScope = '${scope.name}|${widget.progressFilter ?? ''}';
      if (scope == SearchScope.onlineMarks) {
        final auth = ref.read(authProvider);
        entryScope +=
            '|${auth.host ?? ''}|${auth.currentUser?.id ?? ''}|${auth.currentUser?.name ?? ''}';
      }
    }
    return UnifiedSearchHistoryContext(
      contentType: 'audio',
      entryScope: entryScope,
      source: ref.read(audioSourceProvider).name,
    );
  }

  void _onResultSortRequested(SortOrder option, SortDirection direction) {
    unawaited(_performSearch(sortOption: option, sortDirection: direction));
  }

  void _onResultSubtitleFilterRequested(int subtitleFilter) {
    unawaited(_performSearch(subtitleFilter: subtitleFilter));
  }

  void _onOnlineAccountChanged() {
    if (!_hasSubmittedSearch || widget.scope != SearchScope.onlineMarks) return;
    unawaited(
      _historySession.replay(
        context: _historyContext,
        payload: _historyPayload(
          keyword: _activeKeyword,
          searchParams: _activeSearchParams ?? const {},
          conditions: _searchConditions,
        ),
      ),
    );
  }

  void _clearSearch() {
    final wasActive = _hasSubmittedSearch;
    setState(() {
      _searchController.clear();
      _searchConditions.clear();
      _currentSearchType = SearchType.keyword;
      _isExcludeMode = false;
      _minRate = 0;
      _ageRating = AgeRating.all;
      _salesRange = SalesRange.all;
      _activeKeyword = '';
      _activeSearchParams = null;
      _activeScopedQuery = null;
      _hasSubmittedSearch = false;
      _activeSubtitleFilter = 0;
      _activeSortOption = widget.initialSortOption ?? SortOrder.release;
      _activeSortDirection = widget.initialSortDirection ?? SortDirection.desc;
      _autocompleteKey = UniqueKey();
    });
    if (_conditionsReveal.value != 0) _updateConditionsReveal();
    if (wasActive) _loadSuggestions();
  }

  void _restoreQuery({
    required String keyword,
    required Map<String, dynamic>? searchParams,
    SortOrder? sortOption,
    SortDirection? sortDirection,
    int subtitleFilter = 0,
  }) {
    final paramsConditions = searchParams?['conditions'];
    final rawConditions = paramsConditions is List
        ? paramsConditions
        : const [];
    final conditions = <SearchCondition>[];
    for (final value in rawConditions) {
      if (value is! Map) continue;
      final row = Map<String, dynamic>.from(value);
      final typeName = row['searchType']?.toString();
      final typeLabel = row['type']?.toString();
      final type = SearchType.values.firstWhere(
        (candidate) =>
            candidate.name == typeName ||
            candidate.value == typeName ||
            candidate.localizedLabel(context) == typeLabel,
        orElse: () => SearchType.keyword,
      );
      final conditionValue = row['value']?.toString() ?? '';
      if (conditionValue.isEmpty) continue;
      conditions.add(
        SearchCondition(
          id: 'restored-${conditions.length}',
          type: type,
          value: conditionValue,
          isExclude: row['isExclude'] == true,
          sourcePath: row['sourcePath'] as String?,
        ),
      );
    }
    if (conditions.isEmpty && searchParams != null) {
      final metadataType = searchParams.containsKey('tagId')
          ? SearchType.tag
          : searchParams.containsKey('vaId')
          ? SearchType.va
          : searchParams.containsKey('circleId')
          ? SearchType.circle
          : null;
      final metadataName = switch (metadataType) {
        SearchType.tag => searchParams['tagName'],
        SearchType.va => searchParams['vaName'],
        SearchType.circle => searchParams['circleName'],
        _ => null,
      };
      if (metadataType != null && metadataName != null) {
        conditions.add(
          SearchCondition(
            id: 'restored-metadata',
            type: metadataType,
            value: metadataName.toString(),
          ),
        );
      }
    }
    final ageValue =
        searchParams?['ageRatingValue'] ?? searchParams?['ageRating'];
    final salesValue =
        searchParams?['salesRangeValue'] ?? searchParams?['salesRange'];
    _searchController.clear();
    _searchConditions
      ..clear()
      ..addAll(conditions);
    _currentSearchType = conditions.isEmpty
        ? SearchType.keyword
        : conditions.last.type;
    _isExcludeMode = false;
    _minRate = (searchParams?['minRate'] as num?)?.toDouble() ?? 0;
    _ageRating = AgeRating.values.firstWhere(
      (rating) =>
          rating.value == ageValue ||
          rating.localizedLabel(context) == ageValue ||
          rating.label == ageValue,
      orElse: () => AgeRating.all,
    );
    _salesRange = SalesRange.values.firstWhere(
      (range) =>
          range.value.toString() == salesValue?.toString() ||
          range.localizedLabel(context) == salesValue ||
          range.label == salesValue,
      orElse: () => SalesRange.all,
    );
    _activeSortOption =
        sortOption ?? widget.initialSortOption ?? SortOrder.release;
    _activeSortDirection =
        sortDirection ?? widget.initialSortDirection ?? SortDirection.desc;
    _activeSubtitleFilter = subtitleFilter;
    _autocompleteKey = UniqueKey();
  }

  Future<void> _restoreHistory(UnifiedSearchHistoryEntry entry) async {
    final payload = Map<String, dynamic>.from(entry.payload);
    final params = payload['searchParams'];
    final searchParams = params is Map
        ? Map<String, dynamic>.from(params)
        : <String, dynamic>{};
    if (payload['minRate'] != null) {
      searchParams.putIfAbsent('minRate', () => payload['minRate']);
    }
    if (payload['ageRatingValue'] != null) {
      searchParams.putIfAbsent(
        'ageRatingValue',
        () => payload['ageRatingValue'],
      );
    }
    if (payload['salesRangeValue'] != null) {
      searchParams.putIfAbsent(
        'salesRangeValue',
        () => payload['salesRangeValue'],
      );
    }
    final rawSortOption = payload['sortOption'];
    final rawSortDirection = payload['sortDirection'];
    final sortOption = SortOrder.values.firstWhere(
      (value) => value.name == rawSortOption,
      orElse: () => SortOrder.release,
    );
    final sortDirection = SortDirection.values.firstWhere(
      (value) => value.name == rawSortDirection,
      orElse: () => SortDirection.desc,
    );
    setState(() {
      _restoreQuery(
        keyword: payload['keyword']?.toString() ?? '',
        searchParams: searchParams,
        sortOption: sortOption,
        sortDirection: sortDirection,
        subtitleFilter: payload['subtitleFilter'] as int? ?? 0,
      );
      _hasSubmittedSearch = false;
    });
    _updateConditionsReveal();
    final restoredKeyword = payload['keyword']?.toString() ?? '';
    await _historySession.replay(
      context: _historyContext,
      payload: _historyPayload(
        keyword: restoredKeyword,
        searchParams: searchParams,
        conditions: _searchConditions,
      ),
      entry: entry,
    );
    if (!mounted) return;
    unawaited(
      _performSearch(
        conditions: _searchConditions,
        searchParamsOverride: searchParams,
        includeInput: false,
        updateHistory: false,
      ),
    );
  }

  String _searchScopeLabel(BuildContext context) {
    final s = S.of(context);
    return switch (widget.scope!) {
      SearchScope.globalWorks => s.navHome,
      SearchScope.onlineMarks => () {
        final filter = widget.progressFilter;
        if (filter == null || filter.isEmpty) return s.onlineMarks;
        return MyReviewFilter.values
            .firstWhere(
              (value) => value.value == filter,
              orElse: () => MyReviewFilter.all,
            )
            .localizedLabel(context);
      }(),
      SearchScope.history => s.historyRecord,
      SearchScope.playlists => s.playlists,
      SearchScope.downloads => s.downloaded,
    };
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // 必须调用以保持状态
    ref.watch(
      authProvider.select(
        (value) => (value.host, value.currentUser?.id, value.currentUser?.name),
      ),
    );
    ref.listen(
      authProvider.select(
        (value) => (value.host, value.currentUser?.id, value.currentUser?.name),
      ),
      (previous, next) {
        if (previous != null && previous != next) _onOnlineAccountChanged();
      },
    );
    ref.listen<AudioSource>(audioSourceProvider, (previous, next) {
      if (previous == next) return;
      if (widget.scope != null && widget.scope != SearchScope.globalWorks) {
        return;
      }
      final shouldRerun = _hasSubmittedSearch;
      if (next == AudioSource.jpAsmr) {
        setState(() {
          _currentSearchType = SearchType.keyword;
          _searchConditions.removeWhere(
            (condition) =>
                condition.type != SearchType.keyword &&
                condition.type != SearchType.rjNumber,
          );
          _minRate = 0;
          _ageRating = AgeRating.all;
          _salesRange = SalesRange.all;
          _isExcludeMode = false;
        });
      } else if (previous == AudioSource.jpAsmr) {
        setState(() {
          _searchConditions.removeWhere(
            (condition) => condition.sourcePath != null,
          );
          if (_currentSearchType == SearchType.tag ||
              _currentSearchType == SearchType.va ||
              _currentSearchType == SearchType.circle) {
            _currentSearchType = SearchType.keyword;
          }
          _isExcludeMode = false;
        });
      } else {
        if (shouldRerun) _performSearch();
        return;
      }
      _updateConditionsReveal();
      _loadSuggestions();
      if (shouldRerun) _performSearch();
    });
    final isJapaneseGlobalSearch =
        (widget.scope == null || widget.scope == SearchScope.globalWorks) &&
        ref.watch(audioSourceProvider) == AudioSource.jpAsmr;
    final theme = Theme.of(context);
    return GestureDetector(
      // 点击任何地方（包括 AppBar）都取消焦点，关闭下拉框
      onTap: () {
        FocusScope.of(context).unfocus();
      },
      child: Scaffold(
        floatingActionButton: const DownloadFab(),
        appBar: ScrollableAppBar(
          title: Text(
            widget.scope == null || widget.scope == SearchScope.globalWorks
                ? S.of(context).search
                : S.of(context).searchInScope(_searchScopeLabel(context)),
            style: UiTextStyles.pageTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          leading: widget.showBackButton
              ? IconButton(
                  tooltip: S.of(context).back,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                )
              : null,
          automaticallyImplyLeading: false,
          clipBehavior: Clip.none,
          actions: [
            if (_hasSubmittedSearch)
              IconButton(
                tooltip: S.of(context).searchHistory,
                icon: const Icon(Icons.history),
                onPressed: () => setState(() => _hasSubmittedSearch = false),
              ),
          ],
        ),
        resizeToAvoidBottomInset: true, // 自动调整以避免键盘遮挡
        body: LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SearchFilterPanel(
                  key: _filterPanelKey,
                  headerBuilder: (context, filterButton) => Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Row(
                      children: [
                        Expanded(child: _buildSearchInput()),
                        filterButton,
                        IconButton.filled(
                          key: const ValueKey('audio-search-submit'),
                          tooltip: S.of(context).search,
                          onPressed: () => _performSearch(manual: true),
                          icon: const Icon(Icons.search),
                        ),
                      ],
                    ),
                  ),
                  selected: _buildSearchConditionsSection(theme),
                  filters: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight:
                          constraints.maxHeight *
                          (MediaQuery.viewInsetsOf(context).bottom > 0
                              ? .15
                              : .34),
                    ),
                    child: SingleChildScrollView(
                      child: _buildFilterControls(
                        theme,
                        isJapaneseGlobalSearch: isJapaneseGlobalSearch,
                      ),
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _hasSubmittedSearch
                    ? _buildActiveResults()
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: _buildHistorySection(),
                      ),
              ),
            ],
          ),
        ),
      ), // Scaffold 的闭合
    ); // GestureDetector 的闭合
  }

  Widget _buildSearchInput() {
    final isDirectoryType =
        _currentSearchType == SearchType.tag ||
        _currentSearchType == SearchType.va ||
        _currentSearchType == SearchType.circle;
    final canAdd =
        !_isJapaneseGlobalSearch ||
        _currentSearchType == SearchType.keyword ||
        _currentSearchType == SearchType.rjNumber;

    return Row(
      children: [
        Expanded(
          child: isDirectoryType
              ? Autocomplete<_SearchSuggestion>(
                  displayStringForOption: (option) => option.display,
                  focusNode: _searchFocusNode,
                  key: _autocompleteKey,
                  optionsBuilder: (value) => _searchSuggestions(value.text),
                  optionsMaxHeight: 300,
                  textEditingController: _searchController,
                  optionsViewBuilder: (context, onSelected, options) {
                    final highlightedIndex = AutocompleteHighlightedOption.of(
                      context,
                    );
                    return Align(
                      alignment: Alignment.topLeft,
                      child: MaterialPopupSurface(
                        maxHeight: 300,
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          shrinkWrap: true,
                          itemCount: options.length,
                          itemBuilder: (context, index) {
                            final option = options.elementAt(index);
                            return Semantics(
                              button: true,
                              child: InkWell(
                                key: ValueKey(
                                  option.sourcePath ?? option.value,
                                ),
                                onTap: () => onSelected(option),
                                child: Container(
                                  color: highlightedIndex == index
                                      ? Theme.of(context).focusColor
                                      : null,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  child: Text(option.display),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    );
                  },
                  onSelected: (suggestion) => _addSearchCondition(
                    suggestion: suggestion,
                    submit: _submitAfterSuggestion,
                  ),
                  fieldViewBuilder:
                      (context, controller, focusNode, onSubmitted) {
                        if (controller.text != _searchController.text) {
                          controller.value = _searchController.value;
                        }
                        return TextField(
                          controller: controller,
                          focusNode: focusNode,
                          decoration: searchInputDecoration(
                            hintText: _currentSearchType.localizedHint(context),
                            prefixText:
                                _currentSearchType == SearchType.rjNumber
                                ? 'RJ'
                                : null,
                            suffixIcon: _searchInputSuffix(),
                          ),
                          onTap: _loadSuggestionsIfNeeded,
                          textInputAction: TextInputAction.search,
                          onChanged: (_) =>
                              _searchController.value = controller.value,
                          onSubmitted: (_) {
                            if (!_isJapaneseGlobalSearch) {
                              _performSearch(manual: true);
                              return;
                            }
                            _submitAfterSuggestion = true;
                            onSubmitted();
                            if (_searchController.text.trim().isNotEmpty) {
                              _submitAfterSuggestion = false;
                              _performSearch(manual: true);
                            }
                            _submitAfterSuggestion = false;
                          },
                        );
                      },
                )
              : TextField(
                  controller: _searchController,
                  decoration: searchInputDecoration(
                    hintText: _currentSearchType.localizedHint(context),
                    prefixText: _currentSearchType == SearchType.rjNumber
                        ? 'RJ'
                        : null,
                    suffixIcon: _searchInputSuffix(),
                  ),
                  onTap: _loadSuggestionsIfNeeded,
                  keyboardType: _currentSearchType == SearchType.rjNumber
                      ? TextInputType.number
                      : TextInputType.text,
                  inputFormatters: _currentSearchType == SearchType.rjNumber
                      ? [FilteringTextInputFormatter.digitsOnly]
                      : null,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _performSearch(manual: true),
                ),
        ),
        if (canAdd)
          IconButton(
            tooltip: S.of(context).add,
            onPressed: _addSearchCondition,
            icon: const Icon(Icons.add),
          ),
      ],
    );
  }

  Widget _searchInputSuffix() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (_isLoadingSuggestions)
        const Padding(
          padding: EdgeInsets.all(12),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      IconButton(
        tooltip: S.of(context).clear,
        onPressed: _clearSearch,
        icon: const Icon(Icons.clear),
      ),
    ],
  );

  Widget _buildFilterControls(
    ThemeData theme, {
    required bool isJapaneseGlobalSearch,
  }) {
    final isDirectoryType =
        _currentSearchType == SearchType.tag ||
        _currentSearchType == SearchType.va ||
        _currentSearchType == SearchType.circle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FloatingToolbarSurface(
          padding: const EdgeInsets.all(4),
          child: SizedBox(
            height: 48,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: SearchType.values
                    .where(
                      (type) =>
                          !isJapaneseGlobalSearch ||
                          type == SearchType.keyword ||
                          type == SearchType.rjNumber ||
                          type == SearchType.tag ||
                          type == SearchType.va ||
                          type == SearchType.circle,
                    )
                    .map((type) => _buildSearchTypeButton(type, theme))
                    .toList(),
              ),
            ),
          ),
        ),
        if (isDirectoryType)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(
                  _isExcludeMode
                      ? Icons.remove_circle_outline
                      : Icons.info_outline,
                  size: 14,
                  color: _isExcludeMode
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _isExcludeMode
                        ? '${S.of(context).excludeMode}: ${_currentSearchType.localizedLabel(context)}'
                        : S
                              .of(context)
                              .includeModeTapAgainHint(
                                _currentSearchType.localizedLabel(context),
                              ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: _isExcludeMode
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_suggestionError != null)
          if (_suggestionError!.contains('[jp-asmr-verification-required]'))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: JapaneseAsmrAccessPrompt(
                onRetry: _loadSuggestions,
                onVerified: _loadSuggestions,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      S.of(context).loadFailed,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                  IconButton(
                    tooltip: S.of(context).retry,
                    onPressed: _loadSuggestions,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
        if (!isJapaneseGlobalSearch) ...[
          const Divider(height: 24),
          Text(S.of(context).advancedFilter, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          ..._buildAdvancedFilterSections(),
        ],
      ],
    );
  }

  Widget _buildActiveResults() {
    if (widget.scope != null && widget.scope != SearchScope.globalWorks) {
      return ScopedSearchResultScreen(
        query: _activeScopedQuery ?? _buildScopedQuery(_searchConditions),
        session: _scopeSession,
        embedded: true,
        queryRevision: _searchRevision,
      );
    }
    return SearchResultScreen(
      keyword: _activeKeyword,
      searchParams: _activeSearchParams,
      embedded: true,
      queryRevision: _searchRevision,
      initialSortOption: _activeSortOption,
      initialSortDirection: _activeSortDirection,
      initialSubtitleFilter: _activeSubtitleFilter,
      onSortRequested: _onResultSortRequested,
      onSubtitleFilterRequested: _onResultSubtitleFilterRequested,
    );
  }

  Widget _buildHistorySection() {
    final history = ref.watch(unifiedSearchHistoryProvider);
    final notifier = ref.read(unifiedSearchHistoryProvider.notifier);
    final context = _historyContext;
    return SearchHistorySection(
      entries: history.itemsFor(context),
      labelFor: (entry) {
        final displayText = entry.payload['displayText'];
        if (displayText is String && displayText.isNotEmpty) return displayText;
        return entry.payload['keyword']?.toString() ?? '';
      },
      onSelect: (entry) => unawaited(_restoreHistory(entry)),
      onRemove: (entry) => unawaited(notifier.remove(context, entry.id)),
      onClear: () => unawaited(notifier.clear(context)),
      isLoading: history.isLoading,
      canPersist: notifier.canPersist,
    );
  }

  Widget _buildSearchConditionsSection(ThemeData theme) {
    final hidden = !_hasSelectedFilters;
    final selectedChips = <Widget>[
      for (final condition in _searchConditions)
        SearchConditionChip(
          avatar: Icon(
            condition.isExclude
                ? Icons.remove_circle_outline
                : _getSearchTypeIcon(condition.type),
            size: UiIconSize.small,
          ),
          label:
              '${condition.type.localizedLabel(context)}: ${_conditionDisplayValue(condition)}',
          backgroundColor: condition.isExclude
              ? theme.colorScheme.errorContainer
              : theme.colorScheme.secondaryContainer,
          onDeleted: () => _removeSearchCondition(condition.id),
        ),
      if (_minRate > 0)
        SearchConditionChip(
          avatar: const Icon(Icons.star, size: UiIconSize.small),
          label:
              '${S.of(context).minRating}: ${S.of(context).minRatingStars(_minRate.toStringAsFixed(2))}',
          backgroundColor: theme.colorScheme.tertiaryContainer,
        ),
      if (_ageRating != AgeRating.all)
        SearchConditionChip(
          avatar: const Icon(Icons.shield, size: UiIconSize.small),
          label:
              '${S.of(context).ageRatingLabel}: ${_ageRating.localizedLabel(context)}',
          backgroundColor: theme.colorScheme.tertiaryContainer,
        ),
      if (_salesRange != SalesRange.all)
        SearchConditionChip(
          avatar: const Icon(Icons.trending_up, size: UiIconSize.small),
          label: '${S.of(context).salesLabel}: ${_salesRange.label}',
          backgroundColor: theme.colorScheme.tertiaryContainer,
        ),
    ];
    return ExcludeSemantics(
      excluding: hidden,
      child: IgnorePointer(
        ignoring: hidden,
        child: SizeTransition(
          key: const ValueKey('search-conditions-reveal'),
          sizeFactor: _conditionsReveal,
          alignment: Alignment.topCenter,
          child: FadeTransition(
            opacity: _conditionsReveal,
            child: SizedBox(
              height: MediaQuery.textScalerOf(context).scale(40),
              child: ListView.builder(
                controller: _conditionsScrollController,
                scrollDirection: Axis.horizontal,
                itemCount: selectedChips.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: EdgeInsets.only(
                      right: index == selectedChips.length - 1 ? 0 : 6,
                    ),
                    child: selectedChips[index],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _conditionDisplayValue(SearchCondition condition) =>
      condition.type == SearchType.rjNumber
      ? 'RJ${condition.value}'
      : condition.type == SearchType.tag
      ? TagLocalizer.localizeByName(
          condition.value,
          Localizations.localeOf(context),
        )
      : condition.value;

  Widget _buildSearchTypeButton(SearchType type, ThemeData theme) {
    final supportsExclude =
        type == SearchType.tag ||
        type == SearchType.va ||
        type == SearchType.circle;
    final isCurrentType = _currentSearchType == type;
    final isExcluded = isCurrentType && _isExcludeMode && supportsExclude;
    final colors = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Semantics(
        selected: isCurrentType,
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(UiRadii.capsule),
            onTap: () {
              setState(() {
                if (isCurrentType && supportsExclude) {
                  _isExcludeMode = !_isExcludeMode;
                } else {
                  _currentSearchType = type;
                  _isExcludeMode = false;
                  _searchController.clear();
                  _autocompleteKey = UniqueKey();
                }
              });
              if (!isCurrentType) _loadSuggestions();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              height: UiControlSize.compact,
              padding: const EdgeInsets.symmetric(horizontal: UiSpacing.medium),
              decoration: BoxDecoration(
                color: isCurrentType
                    ? (isExcluded
                          ? colors.errorContainer
                          : colors.primaryContainer)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(UiRadii.capsule),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isCurrentType) ...[
                    Icon(
                      isExcluded ? Icons.remove_circle_outline : Icons.check,
                      size: UiIconSize.standard,
                      color: isExcluded
                          ? colors.onErrorContainer
                          : colors.primary,
                    ),
                    const SizedBox(width: UiSpacing.small),
                  ],
                  Text(
                    type.localizedLabel(context),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: isCurrentType
                          ? (isExcluded
                                ? colors.onErrorContainer
                                : colors.primary)
                          : colors.onSurfaceVariant,
                      fontWeight: isCurrentType
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _filterInputDecoration(
    ThemeData theme, {
    required String labelText,
    required Widget prefixIcon,
  }) {
    return InputDecoration(
      labelText: labelText,
      prefixIcon: prefixIcon,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      filled: false,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      labelStyle: theme.textTheme.labelMedium,
    );
  }

  void _handleFilterChange(VoidCallback change) {
    setState(change);
    _updateConditionsReveal();
    if (_hasSubmittedSearch) _performSearch();
  }

  List<Widget> _buildAdvancedFilterSections() {
    final theme = Theme.of(context);
    final filterValueStyle = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.onSurface,
      fontWeight: FontWeight.w500,
    );
    final authState = ref.watch(authProvider);
    final isOfficialServer = ServerUtils.isOfficialServer(authState.host);
    final supportsScopeFiltering =
        widget.scope != null && widget.scope != SearchScope.globalWorks;
    final supportsAdvancedFilters = isOfficialServer || supportsScopeFiltering;

    return [
      if (supportsAdvancedFilters) ...[
        Row(
          children: [
            const Icon(Icons.star, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${S.of(context).minRating}: ${S.of(context).minRatingStars(_minRate.toStringAsFixed(2))}',
                    style: theme.textTheme.bodyMedium,
                  ),
                  Slider(
                    value: _minRate,
                    min: 0,
                    max: 5,
                    divisions: 20,
                    label: _minRate.toStringAsFixed(2),
                    onChanged: (value) => setState(() => _minRate = value),
                    onChangeEnd: (value) =>
                        _handleFilterChange(() => _minRate = value),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
      LayoutBuilder(
        builder: (context, constraints) {
          final ageRatingFilter = FloatingToolbarSurface(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButtonFormField<AgeRating>(
              initialValue: _ageRating,
              isExpanded: true,
              decoration: _filterInputDecoration(
                theme,
                labelText: S.of(context).ageRatingLabel,
                prefixIcon: const Icon(Icons.shield),
              ),
              items: AgeRating.values
                  .where(
                    (rating) =>
                        supportsAdvancedFilters || rating != AgeRating.r15,
                  )
                  .map((rating) {
                    return DropdownMenuItem(
                      value: rating,
                      child: Text(
                        rating.localizedLabel(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: filterValueStyle,
                      ),
                    );
                  })
                  .toList(),
              style: filterValueStyle,
              menuMaxHeight: 300,
              onChanged: (value) => _handleFilterChange(
                () => _ageRating = value ?? AgeRating.all,
              ),
            ),
          );
          final salesRangeFilter = FloatingToolbarSurface(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButtonFormField<SalesRange>(
              initialValue: _salesRange,
              isExpanded: true,
              decoration: _filterInputDecoration(
                theme,
                labelText: S.of(context).salesLabel,
                prefixIcon: const Icon(Icons.trending_up),
              ),
              items: SalesRange.values.map((range) {
                return DropdownMenuItem(
                  value: range,
                  child: Text(
                    range == SalesRange.all
                        ? S.of(context).salesRangeAll
                        : range.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: filterValueStyle,
                  ),
                );
              }).toList(),
              style: filterValueStyle,
              menuMaxHeight: 300,
              onChanged: (value) => _handleFilterChange(
                () => _salesRange = value ?? SalesRange.all,
              ),
            ),
          );
          if (constraints.maxWidth < 600) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ageRatingFilter,
                if (supportsAdvancedFilters) ...[
                  const SizedBox(height: 12),
                  salesRangeFilter,
                ],
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: ageRatingFilter),
              if (supportsAdvancedFilters) ...[
                const SizedBox(width: 12),
                Expanded(child: salesRangeFilter),
              ],
            ],
          );
        },
      ),
      const SizedBox(height: 12),
    ];
  }

  IconData _getSearchTypeIcon(SearchType type) {
    switch (type) {
      case SearchType.keyword:
        return Icons.search;
      case SearchType.rjNumber:
        return Icons.tag;
      case SearchType.tag:
        return Icons.label;
      case SearchType.circle:
        return Icons.group;
      case SearchType.va:
        return Icons.person;
    }
  }
}

class _SearchSuggestion {
  const _SearchSuggestion({
    required this.name,
    required this.value,
    required this.localizedName,
    required this.count,
    this.sourcePath,
  });

  final String name;
  final String value;
  final String localizedName;
  final int count;
  final String? sourcePath;

  String get display => '$localizedName ($count)';
}
