import '../widgets/app_bottom_dock_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';

import '../../l10n/app_localizations.dart';
import '../models/audio_source.dart';
import '../models/search_type.dart';
import '../models/search_query.dart';
import '../models/search_scope_session.dart';
import '../providers/auth_provider.dart';
import '../providers/audio_source_provider.dart';
import '../providers/my_reviews_provider.dart';
import '../providers/search_history_provider.dart';
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
import '../widgets/japanese_asmr_access_prompt.dart';
import 'search_result_screen.dart';
import 'scoped_search_result_screen.dart';
import '../widgets/global_audio_player_wrapper.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({
    super.key,
    this.showBackButton = false,
    this.scope,
    this.progressFilter,
  });

  final bool showBackButton;
  final SearchScope? scope;
  final String? progressFilter;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  late final AnimationController _conditionsReveal;
  final _searchController = TextEditingController();
  final _conditionsScrollController = ScrollController(); // 用于搜索条件横向滚动
  final List<SearchCondition> _searchConditions = [];
  final SearchScopeSession _scopeSession = SearchScopeSession();
  Key _autocompleteKey = UniqueKey(); // 用于强制刷新 Autocomplete

  SearchType _currentSearchType = SearchType.keyword;
  bool _isExcludeMode = false; // 是否处于反选（排除）模式
  double _minRate = 0;
  AgeRating _ageRating = AgeRating.all;
  SalesRange _salesRange = SalesRange.all;
  bool _showAdvancedFilters = false;

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
    _searchController.dispose();
    _suggestionCancelToken?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _conditionsReveal.value = _searchConditions.isEmpty ? 0 : 1;
    }
  }

  void _updateConditionsReveal() {
    final target = _searchConditions.isEmpty ? 0.0 : 1.0;
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
      setState(() {
        _autocompleteKey = UniqueKey();
      });
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

  void _addSearchCondition([_SearchSuggestion? suggestion]) {
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
    setState(() {
      _searchConditions.add(
        SearchCondition(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          type: _currentSearchType,
          value: value,
          isExclude: _isExcludeMode,
          sourcePath: suggestion?.sourcePath,
        ),
      );
      _searchController.clear();
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
  }

  void _removeSearchCondition(String id) {
    setState(() {
      _searchConditions.removeWhere((condition) => condition.id == id);
    });
    if (_searchConditions.isEmpty) _updateConditionsReveal();
  }

  Future<void> _performSearch() async {
    if (_searchConditions.isEmpty) {
      SnackBarUtil.showWarning(
        context,
        S.of(context).addAtLeastOneSearchCondition,
      );
      return;
    }

    if (widget.scope != null && widget.scope != SearchScope.globalWorks) {
      final query = SearchQuery(
        scope: widget.scope!,
        conditions: _searchConditions,
        minRate: _minRate,
        ageRating: _ageRating,
        salesRange: _salesRange,
        progressFilter: widget.progressFilter,
      );
      pushBottomDockRoute(
        context,
        builder: (_) => GlobalAudioPlayerWrapper(
          child: ScopedSearchResultScreen(query: query, session: _scopeSession),
        ),
      );
      return;
    }

    // 构建搜索关键词
    List<String> searchParts = [];
    for (var condition in _searchConditions) {
      if (condition.sourcePath == null) {
        searchParts.add(condition.toSearchString());
      }
    }

    // 添加高级筛选条件
    if (_minRate > 0) {
      searchParts.add('\$rate:${_minRate.toInt()}\$');
    }
    if (_ageRating != AgeRating.all && _ageRating.value.isNotEmpty) {
      searchParts.add('\$age:${_ageRating.value}\$');
    }
    if (_salesRange != SalesRange.all && _salesRange.value > 0) {
      searchParts.add('\$sell:${_salesRange.value}\$');
    }

    final searchKeyword = searchParts.join(' ');

    // 构建搜索条件列表用于显示
    final searchParams = <String, dynamic>{
      'keyword': searchKeyword,
      'conditions': _searchConditions
          .map(
            (c) => {
              'type': c.type.localizedLabel(context),
              'searchType': c.type.name,
              'value': c.value,
              'isExclude': c.isExclude,
              if (c.sourcePath != null) 'sourcePath': c.sourcePath,
            },
          )
          .toList(),
      if (_isJapaneseGlobalSearch) 'source': AudioSource.jpAsmr.name,
    };

    // 添加高级筛选显示
    if (_minRate > 0) {
      searchParams['minRate'] = _minRate;
    }
    if (_ageRating != AgeRating.all) {
      searchParams['ageRating'] = _ageRating.localizedLabel(context);
    }
    if (_salesRange != SalesRange.all) {
      searchParams['salesRange'] = _salesRange.localizedLabel(context);
    }

    // 构建可读的显示文本
    final displayParts = _searchConditions.map((c) {
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

    // 保存搜索历史
    ref
        .read(searchHistoryProvider.notifier)
        .addHistory(
          keyword: searchKeyword,
          displayText: displayText,
          searchParams: searchParams,
        );

    // 跳转到搜索结果页面
    if (mounted) {
      pushBottomDockRoute(
        context,
        builder: (context) => SearchResultScreen(
          keyword: searchKeyword,
          searchTypeLabel: null, // 不使用单一标签
          searchParams: searchParams,
        ),
      );
    }
  }

  /// 从历史记录执行搜索
  void _searchFromHistory(SearchHistoryItem historyItem) {
    pushBottomDockRoute(
      context,
      builder: (context) => SearchResultScreen(
        keyword: historyItem.keyword,
        searchTypeLabel: null,
        searchParams: historyItem.searchParams,
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
    ref.listen<AudioSource>(audioSourceProvider, (previous, next) {
      if (previous == next) return;
      if (widget.scope != null && widget.scope != SearchScope.globalWorks) {
        return;
      }
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
          _showAdvancedFilters = false;
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
        return;
      }
      _updateConditionsReveal();
      _loadSuggestions();
    });
    final isJapaneseGlobalSearch =
        (widget.scope == null || widget.scope == SearchScope.globalWorks) &&
        ref.watch(audioSourceProvider) == AudioSource.jpAsmr;
    final theme = Theme.of(context);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    const contentBottomPadding = 16.0;
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
            // 筛选按钮移到右上角
            if (!isJapaneseGlobalSearch)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FloatingToolbarSurface(
                  child: FloatingToolbarIconButton(
                    icon: _showAdvancedFilters
                        ? Icons.filter_alt
                        : Icons.filter_alt_outlined,
                    tooltip: S.of(context).filter,
                    isSelected: _showAdvancedFilters,
                    onPressed: () {
                      setState(() {
                        _showAdvancedFilters = !_showAdvancedFilters;
                        // 关闭高级筛选时重置参数为默认值
                        if (!_showAdvancedFilters) {
                          _minRate = 0;
                          _ageRating = AgeRating.all;
                          _salesRange = SalesRange.all;
                        }
                      });
                    },
                  ),
                ),
              ),
          ],
        ),
        resizeToAvoidBottomInset: true, // 自动调整以避免键盘遮挡
        body: isLandscape
            ? Container(
                color: theme.colorScheme.surface,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_showAdvancedFilters && !isJapaneseGlobalSearch)
                      _buildAdvancedFiltersSidebar(theme),
                    Expanded(
                      flex: 8,
                      child: SingleChildScrollView(
                        child: Container(
                          padding: EdgeInsets.fromLTRB(
                            _showAdvancedFilters ? 8 : 16,
                            16,
                            16,
                            contentBottomPadding,
                          ),
                          color: theme.colorScheme.surface,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: _buildMainContentChildren(
                              true,
                              isJapaneseGlobalSearch: isJapaneseGlobalSearch,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : SingleChildScrollView(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(
                    16,
                    16,
                    16,
                    contentBottomPadding,
                  ),
                  color: theme.colorScheme.surface,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _buildMainContentChildren(
                      false,
                      isJapaneseGlobalSearch: isJapaneseGlobalSearch,
                    ),
                  ),
                ),
              ),
      ), // Scaffold 的闭合
    ); // GestureDetector 的闭合
  }

  Widget _buildAdvancedFiltersSidebar(ThemeData theme) {
    return Flexible(
      flex: 4,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        S.of(context).advancedFilter,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: S.of(context).close,
                        onPressed: () {
                          setState(() {
                            _showAdvancedFilters = false;
                            _minRate = 0;
                            _ageRating = AgeRating.all;
                            _salesRange = SalesRange.all;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ..._buildAdvancedFilterSections(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildMainContentChildren(
    bool isLandscape, {
    required bool isJapaneseGlobalSearch,
  }) {
    final theme = Theme.of(context);

    return [
      _buildSearchConditionsSection(theme),
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
      if (_currentSearchType == SearchType.tag ||
          _currentSearchType == SearchType.va ||
          _currentSearchType == SearchType.circle)
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
      const SizedBox(height: 12),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: FloatingToolbarSurface(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child:
                  (_currentSearchType == SearchType.tag ||
                      _currentSearchType == SearchType.va ||
                      _currentSearchType == SearchType.circle)
                  ? Autocomplete<_SearchSuggestion>(
                      displayStringForOption: (option) => option.display,
                      key: _autocompleteKey,
                      optionsBuilder: (value) => _searchSuggestions(value.text),
                      optionsMaxHeight: 300,
                      optionsViewBuilder: (context, onSelected, options) {
                        final highlightedIndex =
                            AutocompleteHighlightedOption.of(context);
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
                      onSelected: _addSearchCondition,
                      fieldViewBuilder:
                          (context, controller, focusNode, onSubmitted) {
                            controller.text = _searchController.text;
                            controller.addListener(() {
                              _searchController.text = controller.text;
                            });
                            return TextField(
                              controller: controller,
                              focusNode: focusNode,
                              decoration: _searchInputDecoration(
                                theme,
                                suffixIcon: _isLoadingSuggestions
                                    ? const Padding(
                                        padding: EdgeInsets.all(12.0),
                                        child: SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                      )
                                    : null,
                              ),
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) {
                                if (_isJapaneseGlobalSearch) {
                                  onSubmitted();
                                } else {
                                  _addSearchCondition();
                                }
                              },
                            );
                          },
                    )
                  : TextField(
                      controller: _searchController,
                      decoration: _searchInputDecoration(theme),
                      keyboardType: _currentSearchType == SearchType.rjNumber
                          ? TextInputType.number
                          : TextInputType.text,
                      inputFormatters: _currentSearchType == SearchType.rjNumber
                          ? [FilteringTextInputFormatter.digitsOnly]
                          : null,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _addSearchCondition(),
                    ),
            ),
          ),
          if (!_isJapaneseGlobalSearch ||
              _currentSearchType == SearchType.keyword ||
              _currentSearchType == SearchType.rjNumber) ...[
            const SizedBox(width: 8),
            SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: _addSearchCondition,
                icon: const Icon(Icons.add),
                label: Text(S.of(context).add),
                style: FilledButton.styleFrom(
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
              ),
            ),
          ],
        ],
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
      const SizedBox(height: 12),
      if (!isLandscape && _showAdvancedFilters) ...[
        const Divider(),
        const SizedBox(height: 8),
        ..._buildAdvancedFilterSections(),
      ],
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _searchConditions.isEmpty ? null : _performSearch,
          icon: const Icon(Icons.search),
          label: Text(
            _searchConditions.isEmpty
                ? S.of(context).enterSearchContent
                : '${S.of(context).search} (${_searchConditions.length})',
          ),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: const StadiumBorder(),
          ),
        ),
      ),
      // 搜索历史
      ..._buildSearchHistory(theme),
    ];
  }

  Widget _buildSearchConditionsSection(ThemeData theme) {
    final hidden = _searchConditions.isEmpty;
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.of(context).filter, style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                SizedBox(
                  height: 40,
                  child: ListView.builder(
                    controller: _conditionsScrollController,
                    scrollDirection: Axis.horizontal,
                    itemCount: _searchConditions.length,
                    itemBuilder: (context, index) {
                      final condition = _searchConditions[index];
                      final displayValue = condition.type == SearchType.rjNumber
                          ? 'RJ${condition.value}'
                          : condition.type == SearchType.tag
                          ? TagLocalizer.localizeByName(
                              condition.value,
                              Localizations.localeOf(context),
                            )
                          : condition.value;

                      return Padding(
                        padding: EdgeInsets.only(
                          right: index == _searchConditions.length - 1 ? 0 : 6,
                        ),
                        child: SearchConditionChip(
                          avatar: Icon(
                            condition.isExclude
                                ? Icons.remove_circle_outline
                                : _getSearchTypeIcon(condition.type),
                            size: UiIconSize.small,
                          ),
                          label:
                              '${condition.type.localizedLabel(context)}: $displayValue',
                          backgroundColor: condition.isExclude
                              ? theme.colorScheme.errorContainer
                              : theme.colorScheme.secondaryContainer,
                          onDeleted: () => _removeSearchCondition(condition.id),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 构建搜索历史部分
  List<Widget> _buildSearchHistory(ThemeData theme) {
    if (widget.scope != null && widget.scope != SearchScope.globalWorks) {
      return [];
    }
    final historyState = ref.watch(searchHistoryProvider);

    if (historyState.isLoading) {
      return [];
    }

    if (historyState.items.isEmpty) {
      return [];
    }

    return [
      const SizedBox(height: 24),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(S.of(context).searchHistory, style: theme.textTheme.titleSmall),
          TextButton.icon(
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(S.of(context).clearSearchHistory),
                  content: Text(S.of(context).clearSearchHistoryConfirm),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(S.of(context).cancel),
                    ),
                    FilledButton(
                      onPressed: () {
                        ref.read(searchHistoryProvider.notifier).clearHistory();
                        Navigator.pop(context);
                      },
                      child: Text(S.of(context).confirm),
                    ),
                  ],
                ),
              );
            },
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(S.of(context).clear),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      ...historyState.items.take(10).map((item) {
        return Dismissible(
          key: Key(item.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            color: theme.colorScheme.errorContainer,
            child: Icon(Icons.delete, color: theme.colorScheme.error),
          ),
          onDismissed: (_) {
            ref.read(searchHistoryProvider.notifier).removeHistory(item.id);
          },
          child: ListTile(
            leading: Icon(Icons.history, color: theme.colorScheme.outline),
            title: Text(
              item.displayText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              _formatTimestamp(item.timestamp),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () {
                ref.read(searchHistoryProvider.notifier).removeHistory(item.id);
              },
              tooltip: S.of(context).delete,
            ),
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onTap: () => _searchFromHistory(item),
          ),
        );
      }),
    ];
  }

  /// 格式化时间戳
  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final diff = now.difference(timestamp);

    if (diff.inMinutes < 1) {
      return 'just now';
    } else if (diff.inHours < 1) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inDays < 1) {
      return '${diff.inHours}h ago';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return '${timestamp.month}/${timestamp.day}';
    }
  }

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

  InputDecoration _searchInputDecoration(
    ThemeData theme, {
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: _currentSearchType.localizedHint(context),
      prefixIcon: const Icon(Icons.search),
      prefixText: _currentSearchType == SearchType.rjNumber ? 'RJ' : null,
      prefixStyle: TextStyle(
        color: theme.colorScheme.onSurface,
        fontSize: 16,
        fontWeight: FontWeight.normal,
      ),
      suffixIcon: suffixIcon,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      filled: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
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
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
      Row(
        children: [
          Expanded(
            child: FloatingToolbarSurface(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: DropdownButtonFormField<AgeRating>(
                initialValue: _ageRating,
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
                          style: filterValueStyle,
                        ),
                      );
                    })
                    .toList(),
                style: filterValueStyle,
                menuMaxHeight: 300,
                onChanged: (value) =>
                    setState(() => _ageRating = value ?? AgeRating.all),
              ),
            ),
          ),
          if (supportsAdvancedFilters) ...[
            const SizedBox(width: 12),
            Expanded(
              child: FloatingToolbarSurface(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: DropdownButtonFormField<SalesRange>(
                  initialValue: _salesRange,
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
                        style: filterValueStyle,
                      ),
                    );
                  }).toList(),
                  style: filterValueStyle,
                  menuMaxHeight: 300,
                  onChanged: (value) =>
                      setState(() => _salesRange = value ?? SalesRange.all),
                ),
              ),
            ),
          ],
        ],
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
