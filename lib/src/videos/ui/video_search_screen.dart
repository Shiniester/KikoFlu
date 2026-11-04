import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../../l10n/app_localizations.dart';
import '../../providers/unified_search_history_provider.dart';
import '../../utils/snackbar_util.dart';
import '../../providers/settings_provider.dart';
import '../../providers/works_provider.dart';
import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/search_condition_chip.dart';
import '../../widgets/search_history_section.dart';
import '../../widgets/search_input_decoration.dart';
import '../../widgets/virtualized_sliver_collection.dart';
import '../video_browse_preferences.dart';
import '../missav_client.dart';
import '../video_models.dart';
import '../video_search_history.dart';
import 'video_collection_view.dart';
import 'video_details_screen.dart';

typedef VideoSearchLoader =
    Future<VideoSearchResults> Function(
      String query,
      List<VideoLink> filters,
      bool Function() isCurrent,
    );

typedef VideoSearchFilterLoader =
    Future<VideoCatalogPage> Function(
      VideoSearchFilterKind kind,
      String? pageUrl,
    );

typedef VideoSearchResultItemBuilder =
    Widget Function(
      BuildContext context,
      VideoItem video,
      LayoutType layoutType,
      VoidCallback? onTap,
    );

typedef VideoSearchAccessVerifier =
    Future<bool> Function(
      BuildContext context,
      MissavVerificationRequiredException error,
    );

enum _VideoSearchInputType { keyword, genre, actor, studio, series }

class _VideoSearchSuggestion {
  const _VideoSearchSuggestion.keyword(String value)
    : keyword = value,
      filter = null;

  const _VideoSearchSuggestion.filter(VideoLink value)
    : keyword = null,
      filter = value;

  final String? keyword;
  final VideoLink? filter;

  String get label => keyword ?? filter!.label;
}

class VideoSearchResults {
  VideoSearchResults.catalog(VideoCatalogPage page)
    : page = page,
      videos = page.videos;

  const VideoSearchResults.collection(this.videos) : page = null;

  final VideoCatalogPage? page;
  final List<VideoItem> videos;
}

class VideoSearchScreen extends ConsumerStatefulWidget {
  const VideoSearchScreen({
    super.key,
    required this.title,
    required this.search,
    required this.browsePage,
    this.onOpenVideo,
    this.canOpenVideo,
    this.itemBuilder,
    this.initialQuery,
    this.initialFilters = const [],
    this.loadFilters,
    this.verifyAccess,
    this.accountClient,
    this.historyContext = const UnifiedSearchHistoryContext(
      contentType: 'video',
      entryScope: 'source-directory',
      source: 'missav',
    ),
  });

  final String title;
  final VideoSearchLoader search;
  final Future<VideoCatalogPage> Function(String url) browsePage;
  final void Function(BuildContext context, VideoItem video)? onOpenVideo;
  final bool Function(VideoItem video)? canOpenVideo;
  final VideoSearchResultItemBuilder? itemBuilder;
  final String? initialQuery;
  final List<VideoLink> initialFilters;
  final VideoSearchFilterLoader? loadFilters;
  final VideoSearchAccessVerifier? verifyAccess;
  final MissavClient? accountClient;
  final UnifiedSearchHistoryContext historyContext;

  @override
  ConsumerState<VideoSearchScreen> createState() => _VideoSearchScreenState();
}

class _VideoSearchScreenState extends ConsumerState<VideoSearchScreen> {
  static const _browseDirectorySuggestionIndex = -2;

  static const _legacyVideoHistoryContext = UnifiedSearchHistoryContext(
    contentType: 'video',
    entryScope: 'source-directory',
    source: 'legacy-unknown',
  );

  final TextEditingController _query = TextEditingController();
  final TextEditingController _filterQuery = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final OverlayPortalController _suggestionsOverlay = OverlayPortalController();
  final _suggestionScrollController = ItemScrollController();
  final _suggestionPositions = ItemPositionsListener.create();
  final ScrollController _scrollController = ScrollController();
  final _searchInputAnchorKey = GlobalKey();
  final _filterTypeBarKey = GlobalKey();
  final _selectedFiltersAnchorKey = GlobalKey();
  final List<VideoLink> _filters = [];
  final Map<VideoSearchFilterKind, Map<String, VideoCatalogPage>>
  _loadedFilterPages = {};
  final Map<(VideoSearchFilterKind, String, int), Future<VideoCatalogPage>>
  _filterPageRequests = {};
  final Map<(VideoSearchFilterKind, String), Object> _filterPageErrors = {};
  final Set<(VideoSearchFilterKind, String)> _verifyingFilterPages = {};
  VideoSearchResults? _results;
  String _resultsQuery = '';
  _VideoSearchInputType _inputType = _VideoSearchInputType.keyword;
  int _highlightedSuggestionIndex = -1;
  int _localPage = 1;
  int _filterScopeRevision = 0;
  Object? _error;
  MissavVerificationRequiredException? _verificationError;
  bool _loading = false;
  bool _verifyingAccess = false;
  bool _updateFailedShowingPrevious = false;
  bool _showHistory = false;
  int _request = 0;
  Future<void> Function()? _retryAction;
  ({bool loggedIn, String? accountName})? _accountIdentity;
  late final UnifiedSearchHistorySession _historySession =
      UnifiedSearchHistorySession(
        ref.read(unifiedSearchHistoryProvider.notifier),
      );

  UnifiedSearchHistoryContext get _historyContext {
    final historyContext = widget.historyContext;
    final accountClient = widget.accountClient;
    if (accountClient == null ||
        (historyContext.entryScope != 'favorites' &&
            historyContext.entryScope != 'history')) {
      return historyContext;
    }
    return UnifiedSearchHistoryContext(
      contentType: historyContext.contentType,
      entryScope: historyContext.entryScope,
      source: '${historyContext.source}:${accountClient.accountName ?? ''}',
    );
  }

  @override
  void initState() {
    super.initState();
    _inputFocus.addListener(_onInputFocusChanged);
    _accountIdentity = _readAccountIdentity(widget.accountClient);
    widget.accountClient?.addListener(_onAccountClientChanged);
    final initialQuery = widget.initialQuery?.trim();
    _filters.addAll(widget.initialFilters);
    if ((initialQuery?.isNotEmpty ?? false) || _filters.isNotEmpty) {
      _query.text = initialQuery ?? '';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_runSearch(initialQuery ?? '', filters: _filters));
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant VideoSearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    var filterScopeChanged = false;
    if (oldWidget.loadFilters != widget.loadFilters ||
        oldWidget.historyContext.contentType !=
            widget.historyContext.contentType ||
        oldWidget.historyContext.entryScope !=
            widget.historyContext.entryScope ||
        oldWidget.historyContext.source != widget.historyContext.source) {
      _clearLoadedFilterPages();
      filterScopeChanged = true;
    }
    if (oldWidget.accountClient != widget.accountClient) {
      oldWidget.accountClient?.removeListener(_onAccountClientChanged);
      widget.accountClient?.addListener(_onAccountClientChanged);
      _accountIdentity = _readAccountIdentity(widget.accountClient);
      _invalidateAccountResults();
      filterScopeChanged = true;
    }
    if (filterScopeChanged) {
      _loadFocusedFilterPageAfterFrame();
    }
  }

  ({bool loggedIn, String? accountName})? _readAccountIdentity(
    MissavClient? client,
  ) => client == null
      ? null
      : (loggedIn: client.isLoggedIn, accountName: client.accountName);

  void _onAccountClientChanged() {
    final identity = _readAccountIdentity(widget.accountClient);
    if (identity == _accountIdentity) return;
    final authenticationRequired =
        _accountIdentity?.loggedIn == true &&
        identity?.loggedIn == false &&
        _loading;
    final retryAction = _retryAction;
    _accountIdentity = identity;
    _invalidateAccountResults(
      error: authenticationRequired
          ? const MissavAuthenticationException()
          : null,
    );
    _loadFocusedFilterPageAfterFrame();
    if (authenticationRequired && mounted) {
      _retryAction = retryAction;
    }
  }

  void _invalidateAccountResults({Object? error}) {
    _request++;
    _clearLoadedFilterPages();
    _retryAction = null;
    if (!mounted) return;
    setState(() {
      _results = null;
      _resultsQuery = '';
      _localPage = 1;
      _error = error;
      _verificationError = null;
      _loading = false;
      _verifyingAccess = false;
      _updateFailedShowingPrevious = false;
    });
  }

  @override
  void dispose() {
    _request++;
    _filterScopeRevision++;
    widget.accountClient?.removeListener(_onAccountClientChanged);
    _query.dispose();
    _filterQuery.dispose();
    _inputFocus
      ..removeListener(_onInputFocusChanged)
      ..dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onInputFocusChanged() {
    if (!mounted) return;
    _highlightedSuggestionIndex = -1;
    if (_inputFocus.hasFocus) {
      final kind = _filterKind(_inputType);
      if (kind != null) _ensureFirstFilterPageLoaded(kind);
    } else {
      _suggestionsOverlay.hide();
    }
    setState(() {});
  }

  void _clearLoadedFilterPages() {
    _filterScopeRevision++;
    _loadedFilterPages.clear();
    _filterPageErrors.clear();
    _verifyingFilterPages.clear();
  }

  void _loadFocusedFilterPageAfterFrame() {
    if (!_inputFocus.hasFocus) return;
    final kind = _filterKind(_inputType);
    if (kind == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _inputFocus.hasFocus && _filterKind(_inputType) == kind) {
        _ensureFirstFilterPageLoaded(kind);
      }
    });
  }

  void _ensureFirstFilterPageLoaded(VideoSearchFilterKind kind) {
    final pageKey = (kind, '');
    if (widget.loadFilters == null ||
        _cachedFilterPage(kind, null) != null ||
        _isFilterPageLoading(kind, null) ||
        _filterPageErrors.containsKey(pageKey)) {
      return;
    }
    unawaited(_loadFilterPageQuietly(kind, null));
    setState(() {});
  }

  Future<VideoCatalogPage> _loadFilterPage(
    VideoSearchFilterKind kind,
    String? pageUrl,
  ) {
    final cached = _cachedFilterPage(kind, pageUrl);
    if (cached != null) return Future.value(cached);

    final loader = widget.loadFilters;
    if (loader == null) {
      return Future.error(StateError('Video filters are unavailable'));
    }

    final scopeRevision = _filterScopeRevision;
    final requestKey = (kind, pageUrl ?? '', scopeRevision);
    final currentRequest = _filterPageRequests[requestKey];
    if (currentRequest != null) return currentRequest;

    final pageKey = (kind, pageUrl ?? '');
    _filterPageErrors.remove(pageKey);
    late final Future<VideoCatalogPage> request;
    request = Future<VideoCatalogPage>.sync(() => loader(kind, pageUrl))
        .then(
          (page) {
            if (mounted && scopeRevision == _filterScopeRevision) {
              _cacheFilterPage(kind, pageUrl, page, scopeRevision);
              _filterPageErrors.remove(pageKey);
            }
            return page;
          },
          onError: (Object error, StackTrace stackTrace) {
            if (mounted && scopeRevision == _filterScopeRevision) {
              _filterPageErrors[pageKey] = error;
            }
            Error.throwWithStackTrace(error, stackTrace);
          },
        )
        .whenComplete(() {
          if (identical(_filterPageRequests[requestKey], request)) {
            _filterPageRequests.remove(requestKey);
            if (mounted && scopeRevision == _filterScopeRevision) {
              setState(() {});
            }
          }
        });
    _filterPageRequests[requestKey] = request;
    return request;
  }

  bool _isFilterPageLoading(VideoSearchFilterKind kind, String? pageUrl) =>
      _filterPageRequests.containsKey((
        kind,
        pageUrl ?? '',
        _filterScopeRevision,
      ));

  Future<void> _loadFilterPageQuietly(
    VideoSearchFilterKind kind,
    String? pageUrl,
  ) async {
    try {
      await _loadFilterPage(kind, pageUrl);
    } catch (_) {}
  }

  void _retryFilterPageLoad(VideoSearchFilterKind kind, String? pageUrl) {
    final pageKey = (kind, pageUrl ?? '');
    setState(() => _filterPageErrors.remove(pageKey));
    unawaited(_loadFilterPageQuietly(kind, pageUrl));
    setState(() {});
  }

  Future<void> _verifyAndRetryFilterPage(
    VideoSearchFilterKind kind,
    String? pageUrl,
  ) async {
    final pageKey = (kind, pageUrl ?? '');
    final verification = _filterPageErrors[pageKey];
    final verifyAccess = widget.verifyAccess;
    if (verification is! MissavVerificationRequiredException ||
        verifyAccess == null ||
        _verifyingFilterPages.contains(pageKey)) {
      return;
    }

    final scopeRevision = _filterScopeRevision;
    setState(() => _verifyingFilterPages.add(pageKey));
    var verified = false;
    try {
      verified = await verifyAccess(context, verification);
    } catch (_) {
      verified = false;
    }
    if (!mounted ||
        scopeRevision != _filterScopeRevision ||
        _filterPageErrors[pageKey] != verification) {
      return;
    }
    setState(() => _verifyingFilterPages.remove(pageKey));
    if (verified) _retryFilterPageLoad(kind, pageUrl);
  }

  void _cacheFilterPage(
    VideoSearchFilterKind kind,
    String? requestedUrl,
    VideoCatalogPage page,
    int scopeRevision,
  ) {
    if (!mounted || scopeRevision != _filterScopeRevision) return;
    final pages = _loadedFilterPages.putIfAbsent(kind, () => {});
    pages[requestedUrl ?? ''] = page;
    pages[page.url] = page;
  }

  VideoCatalogPage? _cachedFilterPage(
    VideoSearchFilterKind kind,
    String? pageUrl,
  ) => _loadedFilterPages[kind]?[pageUrl ?? ''];

  Future<void> _runSearch(
    String value, {
    List<VideoLink>? filters,
    bool updateHistory = false,
    bool recordHistory = true,
  }) async {
    final query = value.trim();
    final filtersSnapshot = List<VideoLink>.unmodifiable(filters ?? _filters);
    if (query.isEmpty && filtersSnapshot.isEmpty) {
      _request++;
      _retryAction = null;
      setState(() {
        _results = null;
        _resultsQuery = '';
        _localPage = 1;
        _error = null;
        _verificationError = null;
        _loading = false;
        _updateFailedShowingPrevious = false;
      });
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      return;
    }
    _retryAction = () =>
        _runSearch(query, filters: filtersSnapshot, recordHistory: false);
    final request = ++_request;
    final historyPayload = _historyPayload(query, filtersSnapshot);
    if (recordHistory) {
      unawaited(_historySession.submit(_historyContext, historyPayload));
    } else if (updateHistory) {
      unawaited(_historySession.update(_historyContext, historyPayload));
    }
    setState(() {
      _loading = true;
      _error = null;
      _verificationError = null;
      _updateFailedShowingPrevious = false;
      _showHistory = false;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    try {
      final results = await widget.search(
        query,
        filtersSnapshot,
        () => mounted && request == _request,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _results = results;
        _resultsQuery = query;
        _localPage = 1;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error;
        _verificationError = error is MissavVerificationRequiredException
            ? error
            : null;
        _loading = false;
        _updateFailedShowingPrevious = _results != null;
      });
    }
  }

  void _submitSearch(String value) {
    if (_inputType != _VideoSearchInputType.keyword &&
        value.trim().isNotEmpty) {
      SnackBarUtil.showFromSnackBar(
        context,
        SnackBar(
          content: Text(S.of(context).videoSearchSelectFilterBeforeSearch),
        ),
      );
      return;
    }
    _inputFocus.unfocus();
    unawaited(_runSearch(_query.text));
  }

  Map<String, Object?> _historyPayload(String query, List<VideoLink> filters) =>
      {
        'keyword': query,
        'filters': filters.map((filter) => filter.toJson()).toList(),
      };

  void _searchAfterFilterChange() {
    final hadSearch = _results != null || _loading;
    unawaited(
      _runSearch(
        _query.text,
        updateHistory: hadSearch,
        recordHistory: !hadSearch,
      ),
    );
  }

  void _clearInput() {
    _request++;
    _retryAction = null;
    _query.clear();
    _filterQuery.clear();
    _filters.clear();
    _highlightedSuggestionIndex = -1;
    _inputFocus.unfocus();
    setState(() {
      _results = null;
      _resultsQuery = '';
      _localPage = 1;
      _error = null;
      _verificationError = null;
      _loading = false;
      _updateFailedShowingPrevious = false;
      _showHistory = true;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  String _filterTitle(VideoSearchFilterKind kind, S s) => switch (kind) {
    VideoSearchFilterKind.genre => s.videoFilterGenre,
    VideoSearchFilterKind.actor => s.videoFilterActor,
    VideoSearchFilterKind.studio => s.videoFilterStudio,
    VideoSearchFilterKind.series => s.videoFilterSeries,
  };

  VideoSearchFilterKind? _filterKind(_VideoSearchInputType type) =>
      switch (type) {
        _VideoSearchInputType.keyword => null,
        _VideoSearchInputType.genre => VideoSearchFilterKind.genre,
        _VideoSearchInputType.actor => VideoSearchFilterKind.actor,
        _VideoSearchInputType.studio => VideoSearchFilterKind.studio,
        _VideoSearchInputType.series => VideoSearchFilterKind.series,
      };

  String _inputTypeTitle(_VideoSearchInputType type, S s) => switch (type) {
    _VideoSearchInputType.keyword => s.searchTypeKeyword,
    _VideoSearchInputType.genre => s.videoFilterGenre,
    _VideoSearchInputType.actor => s.videoFilterActor,
    _VideoSearchInputType.studio => s.videoFilterStudio,
    _VideoSearchInputType.series => s.videoFilterSeries,
  };

  IconData _inputTypeIcon(_VideoSearchInputType type) => switch (type) {
    _VideoSearchInputType.keyword => Icons.search,
    _VideoSearchInputType.genre => Icons.category_outlined,
    _VideoSearchInputType.actor => Icons.person_outline,
    _VideoSearchInputType.studio => Icons.business_outlined,
    _VideoSearchInputType.series => Icons.video_collection_outlined,
  };

  Future<void> _openFilterPicker(VideoSearchFilterKind kind) async {
    if (widget.loadFilters == null) return;
    _highlightedSuggestionIndex = -1;
    _inputFocus.unfocus();
    final scopeRevision = _filterScopeRevision;
    final selected = await showResponsiveBottomSheet<VideoLink>(
      context: context,
      builder: (_) => _VideoSearchFilterPicker(
        title: _filterTitle(kind, S.of(context)),
        kind: kind,
        loadFilters: _loadFilterPage,
        verifyAccess: widget.verifyAccess,
        initialPage: _cachedFilterPage(kind, null),
        cachedPage: (pageUrl) => scopeRevision == _filterScopeRevision
            ? _cachedFilterPage(kind, pageUrl)
            : null,
        onPageLoaded: (pageUrl, page) =>
            _cacheFilterPage(kind, pageUrl, page, scopeRevision),
      ),
    );
    if (!mounted || scopeRevision != _filterScopeRevision) {
      return;
    }
    if (selected != null) {
      final wasSelected = _filters.any((filter) => filter.url == selected.url);
      setState(() {
        _highlightedSuggestionIndex = -1;
        _filterQuery.clear();
        if (!wasSelected) _filters.add(selected);
      });
      if (!wasSelected) _searchAfterFilterChange();
    } else {
      setState(() {});
    }
  }

  void _selectFilter(VideoLink filter) {
    if (_filters.any((item) => item.url == filter.url)) return;
    setState(() {
      _highlightedSuggestionIndex = -1;
      _filters.add(filter);
      _filterQuery.clear();
    });
    _inputFocus.unfocus();
    _searchAfterFilterChange();
  }

  void _removeFilter(VideoLink filter) {
    setState(() => _filters.removeWhere((item) => item.url == filter.url));
    _searchAfterFilterChange();
  }

  Widget _filterControls(S s, UnifiedSearchHistoryState history) {
    final loadFilters = widget.loadFilters;
    final colorScheme = Theme.of(context).colorScheme;
    final selected = _filters.isEmpty
        ? null
        : Padding(
            key: _selectedFiltersAnchorKey,
            padding: const EdgeInsets.only(bottom: 4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SizedBox(
                  height: MediaQuery.textScalerOf(context).scale(40),
                  child: ListView.separated(
                    key: const ValueKey('video-search-selected-filters'),
                    scrollDirection: Axis.horizontal,
                    itemCount: _filters.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final filter = _filters[index];
                      return ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth,
                        ),
                        child: Tooltip(
                          message: filter.label,
                          child: Semantics(
                            label: filter.label,
                            child: SearchConditionChip(
                              key: ValueKey(
                                'selected-video-filter-${filter.url}',
                              ),
                              label: filter.label,
                              maxLines: 1,
                              avatar: Icon(
                                _iconForLink(filter),
                                size: 16,
                                color: colorScheme.onSecondaryContainer,
                              ),
                              backgroundColor: colorScheme.secondaryContainer,
                              onDeleted: () => _removeFilter(filter),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          );
    final scrollBehavior = ScrollConfiguration.of(context);
    if (loadFilters == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSearchInputRow(s, history),
            if (selected != null)
              ScrollConfiguration(
                behavior: scrollBehavior.copyWith(
                  dragDevices: {
                    ...scrollBehavior.dragDevices,
                    PointerDeviceKind.mouse,
                  },
                ),
                child: selected,
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _buildSearchInputRow(s, history),
          ),
          if (selected != null)
            ScrollConfiguration(
              behavior: scrollBehavior.copyWith(
                dragDevices: {
                  ...scrollBehavior.dragDevices,
                  PointerDeviceKind.mouse,
                },
              ),
              child: selected,
            ),
          SizedBox(
            key: _filterTypeBarKey,
            height: 48,
            child: ScrollConfiguration(
              behavior: scrollBehavior.copyWith(
                dragDevices: {
                  ...scrollBehavior.dragDevices,
                  PointerDeviceKind.mouse,
                },
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: _VideoSearchInputType.values
                      .map((type) => _buildSearchTypeButton(type, s))
                      .toList(growable: false),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchTypeButton(_VideoSearchInputType type, S s) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isSelected = _inputType == type;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Semantics(
        selected: isSelected,
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () {
              if (_inputType != type) {
                setState(() {
                  _inputType = type;
                  _filterQuery.clear();
                  _highlightedSuggestionIndex = -1;
                });
              }
              _inputFocus.requestFocus();
              _suggestionsOverlay.show();
              final kind = _filterKind(type);
              if (kind != null) _ensureFirstFilterPageLoaded(kind);
            },
            child: AnimatedContainer(
              key: ValueKey('video-search-type-${type.name}'),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: isSelected
                    ? colors.primaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isSelected) ...[
                    Icon(_inputTypeIcon(type), size: 18, color: colors.primary),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    _inputTypeTitle(type, s),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: isSelected
                          ? colors.primary
                          : colors.onSurfaceVariant,
                      fontWeight: isSelected ? FontWeight.w700 : null,
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

  List<_VideoSearchSuggestion> _autocompleteOptions(
    UnifiedSearchHistoryState history,
  ) {
    final filterKind = _filterKind(_inputType);
    final query =
        (_inputType == _VideoSearchInputType.keyword
                ? _query.text
                : _filterQuery.text)
            .trim()
            .toLowerCase();
    if (filterKind == null) {
      return [
        for (final entry in _historyEntries(history))
          if (entry.payload['keyword'] case final String keyword
              when keyword.isNotEmpty &&
                  (query.isEmpty || keyword.toLowerCase().contains(query)))
            _VideoSearchSuggestion.keyword(keyword),
      ];
    }

    final kind = filterKind;
    final links = <String, VideoLink>{};
    for (final page
        in _loadedFilterPages[kind]?.values ?? const <VideoCatalogPage>[]) {
      for (final link in page.links) {
        if (!_filters.any((filter) => filter.url == link.url) &&
            (query.isEmpty || link.label.toLowerCase().contains(query))) {
          links[link.url] = link;
        }
      }
    }
    return [
      for (final link in links.values) _VideoSearchSuggestion.filter(link),
    ];
  }

  Widget _buildAutocompleteOverlay(
    S s,
    UnifiedSearchHistoryState history,
    OverlayChildLayoutInfo info,
  ) {
    if (!_inputFocus.hasFocus) return const SizedBox.shrink();
    final filterKind = _filterKind(_inputType);
    final options = _autocompleteOptions(history);
    final historyEntries = _historyEntries(history);
    final targetRect = MatrixUtils.transformRect(
      info.childPaintTransform,
      Offset.zero & info.childSize,
    );
    var dropdownAnchorBottom = targetRect.bottom;
    final anchorObject = _searchInputAnchorKey.currentContext
        ?.findRenderObject();
    final typeBarContext = _filterTypeBarKey.currentContext;
    final lowerControlContext =
        typeBarContext ??
        (_filters.isNotEmpty ? _selectedFiltersAnchorKey.currentContext : null);
    final lowerControlObject = lowerControlContext?.findRenderObject();
    if (anchorObject is RenderBox &&
        lowerControlObject is RenderBox &&
        anchorObject.hasSize &&
        lowerControlObject.hasSize) {
      final anchorBottom = anchorObject.localToGlobal(
        Offset(0, anchorObject.size.height),
      );
      final controlsBottom = lowerControlObject.localToGlobal(
        Offset(0, lowerControlObject.size.height),
      );
      dropdownAnchorBottom += controlsBottom.dy - anchorBottom.dy + 8;
    }
    final mediaQuery = MediaQuery.of(context);
    final usableTop = mediaQuery.padding.top;
    final usableBottom =
        info.overlaySize.height -
        mediaQuery.viewInsets.bottom -
        mediaQuery.padding.bottom;
    final spaceBelow = (usableBottom - dropdownAnchorBottom - 4)
        .clamp(0.0, 240.0)
        .toDouble();
    final spaceAbove = (targetRect.top - usableTop - 4)
        .clamp(0.0, 240.0)
        .toDouble();
    final opensAbove = spaceBelow < 96 && spaceAbove > spaceBelow;
    final maxHeight = opensAbove ? spaceAbove : spaceBelow;
    final top = opensAbove
        ? targetRect.top - maxHeight - 4
        : dropdownAnchorBottom + 4;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final pageKey = filterKind == null ? null : (filterKind, '');
    final pageError = pageKey == null ? null : _filterPageErrors[pageKey];
    final isLoadingFilterPage =
        filterKind != null && _isFilterPageLoading(filterKind, null);
    final itemHeaderCount = filterKind == null ? 0 : 1;
    final itemContentCount = options.isEmpty ? 1 : options.length;
    final itemFooterCount = filterKind == null ? 0 : 1;

    Widget emptyState() {
      if (filterKind != null && isLoadingFilterPage) {
        return Padding(
          key: const ValueKey('video-search-directory-loading'),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text(s.loading),
            ],
          ),
        );
      }
      if (filterKind != null && pageError != null) {
        return Padding(
          key: const ValueKey('video-search-directory-error'),
          padding: const EdgeInsets.all(12),
          child: Text(
            pageError is MissavVerificationRequiredException
                ? s.videoVerificationRequired
                : s.videoLoadFailed,
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(12),
        child: history.isLoading && filterKind == null
            ? const LinearProgressIndicator()
            : Text(
                filterKind == null && historyEntries.isEmpty
                    ? s.noSearchHistory
                    : s.noResults,
              ),
      );
    }

    Widget filterSuggestion(int index) {
      final option = options[index];
      final selected = index == _highlightedSuggestionIndex;
      return MouseRegion(
        onEnter: (_) {
          if (_highlightedSuggestionIndex != index) {
            setState(() => _highlightedSuggestionIndex = index);
          }
        },
        child: Semantics(
          button: true,
          selected: selected,
          label: option.label,
          child: Material(
            color: selected
                ? colorScheme.secondaryContainer
                : Colors.transparent,
            child: InkWell(
              key: ValueKey(
                option.keyword == null
                    ? 'video-search-filter-suggestion-${option.filter!.url}'
                    : 'video-search-keyword-suggestion-${option.keyword}',
              ),
              canRequestFocus: false,
              onTap: () => _selectAutocompleteOption(option),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      option.filter == null
                          ? Icons.history
                          : _iconForLink(option.filter!),
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Tooltip(
                        message: option.label,
                        child: Text(
                          option.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
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

    Widget footer() {
      if (filterKind == null) return const SizedBox.shrink();
      final pageKey = (filterKind, '');
      final verifying = _verifyingFilterPages.contains(pageKey);
      final browseAllHighlighted =
          _highlightedSuggestionIndex == _browseDirectorySuggestionIndex;
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: 4,
          runSpacing: 4,
          children: [
            if (pageError != null)
              TextButton(
                key: const ValueKey('video-search-directory-retry'),
                onPressed: isLoadingFilterPage
                    ? null
                    : () => _retryFilterPageLoad(filterKind, null),
                child: Text(s.retry),
              ),
            if (pageError is MissavVerificationRequiredException &&
                widget.verifyAccess != null)
              TextButton.icon(
                key: const ValueKey('video-search-directory-verify'),
                onPressed: verifying
                    ? null
                    : () => _verifyAndRetryFilterPage(filterKind, null),
                icon: verifying
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_user_outlined),
                label: Text(s.videoVerifyAccess),
              ),
            Tooltip(
              message: s.videoSearchBrowseAllDirectory,
              child: Semantics(
                selected: browseAllHighlighted,
                child: TextButton.icon(
                  key: const ValueKey('video-search-browse-all'),
                  style: browseAllHighlighted
                      ? TextButton.styleFrom(
                          backgroundColor: colorScheme.secondaryContainer,
                          foregroundColor: colorScheme.onSecondaryContainer,
                        )
                      : null,
                  onPressed: () => _openFilterPicker(filterKind),
                  icon: const Icon(Icons.open_in_new),
                  label: Text(
                    s.videoSearchBrowseAllDirectory,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Positioned(
      left: targetRect.left,
      top: top,
      width: targetRect.width,
      child: TextFieldTapRegion(
        child: Material(
          key: const ValueKey('video-search-suggestions'),
          elevation: 6,
          color: colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: {
                  ...ScrollConfiguration.of(context).dragDevices,
                  PointerDeviceKind.mouse,
                },
              ),
              child: ScrollablePositionedList.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: itemHeaderCount + itemContentCount + itemFooterCount,
                itemScrollController: _suggestionScrollController,
                itemPositionsListener: _suggestionPositions,
                itemBuilder: (context, index) {
                  if (filterKind != null && index == 0) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: Text(
                        s.videoSearchLoadedDirectoryPagesHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  final contentIndex = index - itemHeaderCount;
                  if (contentIndex < itemContentCount) {
                    return options.isEmpty
                        ? emptyState()
                        : filterSuggestion(contentIndex);
                  }
                  return footer();
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _scrollHighlightedSuggestionIntoView() {
    final highlightedIndex = _highlightedSuggestionIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _highlightedSuggestionIndex != highlightedIndex ||
          !_suggestionScrollController.isAttached) {
        return;
      }
      final filterKind = _filterKind(_inputType);
      final options = _autocompleteOptions(
        ref.read(unifiedSearchHistoryProvider),
      );
      final headerCount = filterKind == null ? 0 : 1;
      final contentCount = options.isEmpty ? 1 : options.length;
      final itemIndex = highlightedIndex == _browseDirectorySuggestionIndex
          ? (filterKind == null ? -1 : headerCount + contentCount)
          : highlightedIndex >= 0 && highlightedIndex < options.length
          ? headerCount + highlightedIndex
          : -1;
      if (itemIndex < 0) return;

      final highlightedIsVisible = _suggestionPositions.itemPositions.value.any(
        (position) =>
            position.index == itemIndex &&
            position.itemLeadingEdge >= 0 &&
            position.itemTrailingEdge <= 1,
      );
      if (!highlightedIsVisible) {
        _suggestionScrollController.jumpTo(index: itemIndex);
      }
    }, debugLabel: 'VideoSearchOptions.ensureVisible');
  }

  KeyEventResult _handleAutocompleteKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final filterKind = _filterKind(_inputType);
    final options = _autocompleteOptions(
      ref.read(unifiedSearchHistoryProvider),
    );
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (options.isEmpty && filterKind == null) return KeyEventResult.ignored;
      _suggestionsOverlay.show();
      setState(() {
        if (_highlightedSuggestionIndex == _browseDirectorySuggestionIndex) {
          _highlightedSuggestionIndex = options.isEmpty ? -1 : 0;
        } else if (_highlightedSuggestionIndex < options.length - 1) {
          _highlightedSuggestionIndex++;
        } else if (filterKind != null) {
          _highlightedSuggestionIndex = _browseDirectorySuggestionIndex;
        } else {
          _highlightedSuggestionIndex = 0;
        }
      });
      _scrollHighlightedSuggestionIntoView();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_highlightedSuggestionIndex == _browseDirectorySuggestionIndex) {
        setState(() => _highlightedSuggestionIndex = options.length - 1);
        _scrollHighlightedSuggestionIntoView();
        return KeyEventResult.handled;
      }
      if (_highlightedSuggestionIndex > 0) {
        setState(() => _highlightedSuggestionIndex--);
        _scrollHighlightedSuggestionIntoView();
        return KeyEventResult.handled;
      }
      if (_highlightedSuggestionIndex == 0) {
        setState(() => _highlightedSuggestionIndex = -1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _inputFocus.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onInputSubmitted(String value) {
    final kind = _filterKind(_inputType);
    if (_highlightedSuggestionIndex == _browseDirectorySuggestionIndex &&
        kind != null) {
      unawaited(_openFilterPicker(kind));
      return;
    }
    final options = _autocompleteOptions(
      ref.read(unifiedSearchHistoryProvider),
    );
    final index = _highlightedSuggestionIndex;
    if (index >= 0 && index < options.length) {
      _selectAutocompleteOption(options[index]);
      return;
    }
    _submitSearch(value);
  }

  void _selectAutocompleteOption(_VideoSearchSuggestion option) {
    final keyword = option.keyword;
    if (keyword != null) {
      _query.value = TextEditingValue(
        text: keyword,
        selection: TextSelection.collapsed(offset: keyword.length),
      );
      setState(() => _highlightedSuggestionIndex = -1);
      _inputFocus.unfocus();
      return;
    }
    _selectFilter(option.filter!);
  }

  Widget _buildSearchInputRow(S s, UnifiedSearchHistoryState history) {
    final controller = _inputType == _VideoSearchInputType.keyword
        ? _query
        : _filterQuery;
    return Row(
      children: [
        Expanded(
          child: OverlayPortal.overlayChildLayoutBuilder(
            controller: _suggestionsOverlay,
            overlayChildBuilder: (context, info) =>
                _buildAutocompleteOverlay(s, history, info),
            child: Focus(
              canRequestFocus: false,
              onKeyEvent: _handleAutocompleteKey,
              child: SizedBox(
                key: _searchInputAnchorKey,
                child: TextField(
                  key: const ValueKey('video-search-input'),
                  controller: controller,
                  focusNode: _inputFocus,
                  autofocus:
                      widget.initialQuery == null &&
                      widget.initialFilters.isEmpty,
                  textInputAction: TextInputAction.search,
                  onTap: _suggestionsOverlay.show,
                  onSubmitted: _onInputSubmitted,
                  onChanged: (_) {
                    _suggestionsOverlay.show();
                    setState(() => _highlightedSuggestionIndex = -1);
                  },
                  decoration: searchInputDecoration(
                    hintText: s.videoSearchHint,
                    prefixText: _inputType == _VideoSearchInputType.keyword
                        ? null
                        : '${_inputTypeTitle(_inputType, s)} · ',
                    suffixIcon: IconButton(
                      tooltip: s.clear,
                      onPressed:
                          _query.text.isEmpty &&
                              _filterQuery.text.isEmpty &&
                              _filters.isEmpty
                          ? null
                          : _clearInput,
                      icon: const Icon(Icons.clear),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('video-search-submit'),
          tooltip: s.search,
          onPressed: () => _submitSearch(controller.text),
          icon: const Icon(Icons.search),
        ),
      ],
    );
  }

  IconData _iconForLink(VideoLink filter) {
    return switch (filter.kind) {
      VideoLinkKind.actor => Icons.person_outline,
      VideoLinkKind.studio => Icons.business_outlined,
      VideoLinkKind.category => Icons.category_outlined,
      VideoLinkKind.tag => Icons.category_outlined,
      VideoLinkKind.collection => Icons.video_collection_outlined,
      _ => Icons.label_outline,
    };
  }

  Future<void> _goToPage(int pageNumber) async {
    final page = _results?.page;
    if (page == null) return;
    await _browsePage(page.pageUrl(pageNumber));
  }

  Future<void> _browsePage(String url) async {
    if (_results?.page == null) return;
    _retryAction = () => _browsePage(url);
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
      _verificationError = null;
      _updateFailedShowingPrevious = false;
    });
    try {
      final nextPage = await widget.browsePage(url);
      if (!mounted || request != _request) return;
      setState(() {
        _results = VideoSearchResults.catalog(nextPage);
        _localPage = 1;
        _loading = false;
      });
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error.toString();
        _verificationError = error is MissavVerificationRequiredException
            ? error
            : null;
        _loading = false;
        _updateFailedShowingPrevious = _results != null;
      });
    }
  }

  Future<void> _verifyAndRetry() async {
    final verification = _verificationError;
    final verifyAccess = widget.verifyAccess;
    if (verification == null || verifyAccess == null || _verifyingAccess) {
      return;
    }
    final request = _request;
    setState(() => _verifyingAccess = true);
    var verified = false;
    try {
      verified = await verifyAccess(context, verification);
    } catch (_) {
      verified = false;
    } finally {
      if (mounted) setState(() => _verifyingAccess = false);
    }
    if (!mounted ||
        !verified ||
        request != _request ||
        verification != _verificationError) {
      return;
    }
    final retry = _retryAction;
    if (retry != null) {
      await retry();
    } else {
      await _runSearch(_query.text);
    }
  }

  void _openVideo(VideoItem video) {
    final canOpen = widget.canOpenVideo?.call(video) ?? true;
    if (!canOpen) return;
    final callback = widget.onOpenVideo;
    if (callback != null) {
      callback(context, video);
    } else {
      final collectionKey = switch (widget.historyContext.entryScope) {
        'favorites' || 'history' => widget.historyContext.entryScope,
        _ => null,
      };
      pushWorkDetailRoute(
        context,
        builder: (_) => VideoDetailsScreen(
          video: video,
          searchCollectionKey: collectionKey,
        ),
      );
    }
  }

  List<UnifiedSearchHistoryEntry> _historyEntries(
    UnifiedSearchHistoryState history,
  ) {
    final context = _historyContext;
    final entries = [
      ...history.itemsFor(context),
      if (context.entryScope == 'source-directory' &&
          context != _legacyVideoHistoryContext)
        ...history.itemsFor(_legacyVideoHistoryContext),
    ]..sort((left, right) => right.timestamp.compareTo(left.timestamp));
    return entries;
  }

  String _historyLabel(UnifiedSearchHistoryEntry entry) {
    final keyword = entry.payload['keyword'];
    final labels = [
      if (keyword is String && keyword.isNotEmpty) keyword,
      if (entry.payload['filters'] case final List filters)
        for (final filter in filters)
          if (filter is Map && filter['label'] is String)
            filter['label'] as String,
    ];
    return labels.join(' · ');
  }

  List<VideoLink> _historyFilters(UnifiedSearchHistoryEntry entry) {
    final filters = entry.payload['filters'];
    if (filters is! List) return const [];
    return [
      for (final filter in filters)
        if (filter is Map)
          VideoLink.fromJson(Map<String, dynamic>.from(filter)),
    ];
  }

  void _replayHistory(UnifiedSearchHistoryEntry entry) {
    final keyword = entry.payload['keyword'];
    final query = keyword is String ? keyword : '';
    final filters = _historyFilters(entry);
    setState(() {
      _inputType = _VideoSearchInputType.keyword;
      _filterQuery.clear();
      _query.text = query;
      _filters
        ..clear()
        ..addAll(filters);
    });
    unawaited(
      _historySession.replay(
        context: _historyContext,
        payload: _historyPayload(query, filters),
        entry: entry,
      ),
    );
    unawaited(_runSearch(query, filters: filters, recordHistory: false));
  }

  void _removeHistoryEntry(UnifiedSearchHistoryEntry entry) {
    unawaited(
      ref
          .read(unifiedSearchHistoryProvider.notifier)
          .remove(entry.context, entry.id),
    );
    final keyword = entry.payload['keyword'];
    if (entry.context == _legacyVideoHistoryContext && keyword is String) {
      unawaited(ref.read(videoSearchHistoryProvider.notifier).remove(keyword));
    }
  }

  Future<void> _clearSearchHistory() async {
    final history = ref.read(unifiedSearchHistoryProvider.notifier);
    final historyContext = _historyContext;
    await history.clear(historyContext);
    if (historyContext.entryScope == 'source-directory') {
      await history.clear(_legacyVideoHistoryContext);
      await ref.read(videoSearchHistoryProvider.notifier).clear();
    }
    if (mounted) {
      SnackBarUtil.showFromSnackBar(
        context,
        SnackBar(content: Text(S.of(context).searchHistoryCleared)),
      );
    }
  }

  Widget _history(UnifiedSearchHistoryState history) {
    final entries = _historyEntries(history);
    return SingleChildScrollView(
      controller: _scrollController,
      child: SearchHistorySection(
        entries: entries,
        labelFor: _historyLabel,
        onSelect: _replayHistory,
        onRemove: _removeHistoryEntry,
        onClear: () => unawaited(_clearSearchHistory()),
        isLoading: history.isLoading,
        canPersist: ref.read(unifiedSearchHistoryProvider.notifier).canPersist,
      ),
    );
  }

  Widget _resultItem(BuildContext context, VideoItem video, LayoutType layout) {
    final canOpen = widget.canOpenVideo?.call(video) ?? true;
    final onTap = canOpen ? () => _openVideo(video) : null;
    final customBuilder = widget.itemBuilder;
    if (customBuilder != null) {
      return customBuilder(context, video, layout, onTap);
    }
    return VideoCard(
      video: video,
      layoutType: layout,
      onTap: onTap,
      onOpenLink: _selectFilter,
    );
  }

  Widget _resultsView(VideoSearchResults results, LayoutType layout) {
    final s = S.of(context);
    final page = results.page;
    final pageSize = ref.watch(pageSizeProvider);
    final hasSourcePagination =
        page != null &&
        (page.previousUrl != null ||
            page.nextUrl != null ||
            page.jumpMaxPage != null);
    final localPageCount = ((results.videos.length + pageSize - 1) ~/ pageSize)
        .clamp(1, 1 << 30)
        .toInt();
    final hasLocalPagination =
        !hasSourcePagination && results.videos.length > pageSize;
    final localPage = _localPage.clamp(1, localPageCount).toInt();
    final videos = hasLocalPagination
        ? results.videos
              .skip((localPage - 1) * pageSize)
              .take(pageSize)
              .toList(growable: false)
        : results.videos;
    final pagination = hasSourcePagination
        ? VirtualizedPagination(
            currentPage: page.currentPage,
            pageSize: page.videos.length.clamp(1, 1000).toInt(),
            totalCount: null,
            jumpMaxPage: page.jumpMaxPage,
            hasMore: page.nextUrl != null,
            isLoading: _loading,
            onPreviousPage: page.previousUrl == null
                ? null
                : () => _browsePage(page.previousUrl!),
            onNextPage: page.nextUrl == null
                ? null
                : () => _browsePage(page.nextUrl!),
            onGoToPage: page.jumpMaxPage == null ? null : _goToPage,
            showWhenEmpty: true,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          )
        : VirtualizedPagination(
            currentPage: localPage,
            pageSize: pageSize,
            totalCount: results.videos.length,
            hasMore: localPage < localPageCount,
            isLoading: _loading,
            onPreviousPage: hasLocalPagination && localPage > 1
                ? () => setState(() => _localPage = localPage - 1)
                : null,
            onNextPage: hasLocalPagination && localPage < localPageCount
                ? () => setState(() => _localPage = localPage + 1)
                : null,
            onGoToPage: hasLocalPagination
                ? (targetPage) => setState(() => _localPage = targetPage)
                : null,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          );
    return Column(
      children: [
        Expanded(
          child: VideoCollectionView(
            items: videos,
            layoutType: layout,
            itemId: (video) => video.id,
            controller: _scrollController,
            pageStorageKey: PageStorageKey<String>(
              'video-search-results-$_resultsQuery',
            ),
            emptyBuilder: (_) => Center(child: Text(s.noResults)),
            itemBuilder: (context, video, _) =>
                _resultItem(context, video, layout),
            pagination: pagination,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final canPop = ModalRoute.of(context)?.canPop == true;
    final history = ref.watch(unifiedSearchHistoryProvider);
    final layout = ref.watch(videoBrowseLayoutProvider);
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        leadingWidth: 48,
        titleSpacing: canPop ? 0 : null,
        leading: canPop
            ? IconButton(
                tooltip: s.back,
                icon: const Icon(Icons.arrow_back),
                visualDensity: const VisualDensity(horizontal: -2),
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        automaticallyImplyLeading: false,
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const ValueKey('video-search-layout-toggle'),
            tooltip: s.layout,
            icon: Icon(switch (layout) {
              LayoutType.bigGrid => Icons.grid_view,
              LayoutType.smallGrid => Icons.apps,
              LayoutType.list => Icons.view_list,
            }),
            visualDensity: const VisualDensity(horizontal: -2),
            onPressed: () =>
                ref.read(videoBrowseLayoutProvider.notifier).cycle(),
          ),
          IconButton(
            key: const ValueKey('video-search-history-toggle'),
            tooltip: _showHistory ? s.close : s.searchHistory,
            icon: const Icon(Icons.history),
            visualDensity: const VisualDensity(horizontal: -2),
            onPressed: () {
              _inputFocus.unfocus();
              setState(() => _showHistory = !_showHistory);
            },
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * .6,
              ),
              child: SingleChildScrollView(
                key: const ValueKey('video-search-top-controls'),
                child: Column(
                  children: [
                    _filterControls(s, history),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _error is MissavAuthenticationException
                                  ? s.videoLoginRequired
                                  : _updateFailedShowingPrevious &&
                                        _results != null
                                  ? s.searchUpdateFailedShowingPrevious
                                  : _verificationError == null
                                  ? s.videoLoadFailed
                                  : s.videoVerificationRequired,
                            ),
                            if (_updateFailedShowingPrevious &&
                                _results != null &&
                                _verificationError != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(s.videoVerificationRequired),
                              ),
                            Wrap(
                              alignment: WrapAlignment.end,
                              children: [
                                if (_verificationError != null &&
                                    widget.verifyAccess != null)
                                  TextButton.icon(
                                    onPressed: _verifyingAccess
                                        ? null
                                        : _verifyAndRetry,
                                    icon: const Icon(
                                      Icons.verified_user_outlined,
                                    ),
                                    label: Text(s.videoVerifyAccess),
                                  ),
                                TextButton(
                                  onPressed: _loading
                                      ? null
                                      : () =>
                                            _retryAction?.call() ??
                                            _runSearch(_query.text),
                                  child: Text(s.retry),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_loading && _results != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Semantics(
                  liveRegion: true,
                  child: Text(s.searchUpdating),
                ),
              ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _showHistory
                  ? _history(history)
                  : _results != null
                  ? _resultsView(_results!, layout)
                  : _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _history(history),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoSearchFilterPicker extends StatefulWidget {
  const _VideoSearchFilterPicker({
    required this.title,
    required this.kind,
    required this.loadFilters,
    required this.initialPage,
    required this.cachedPage,
    required this.onPageLoaded,
    this.verifyAccess,
  });

  final String title;
  final VideoSearchFilterKind kind;
  final VideoSearchFilterLoader loadFilters;
  final VideoCatalogPage? initialPage;
  final VideoCatalogPage? Function(String? pageUrl) cachedPage;
  final void Function(String? pageUrl, VideoCatalogPage page) onPageLoaded;
  final VideoSearchAccessVerifier? verifyAccess;

  @override
  State<_VideoSearchFilterPicker> createState() =>
      _VideoSearchFilterPickerState();
}

class _VideoSearchFilterPickerState extends State<_VideoSearchFilterPicker> {
  VideoCatalogPage? _page;
  String? _requestedUrl;
  String? _error;
  MissavVerificationRequiredException? _verificationError;
  bool _loading = true;
  bool _verifyingAccess = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage;
    _loading = _page == null;
    if (_page == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load(null));
      });
    }
  }

  Future<void> _load(String? pageUrl) async {
    _requestedUrl = pageUrl;
    final cached = widget.cachedPage(pageUrl);
    if (cached != null) {
      _request++;
      setState(() {
        _page = cached;
        _error = null;
        _verificationError = null;
        _loading = false;
      });
      return;
    }
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
      _verificationError = null;
    });
    try {
      final page = await widget.loadFilters(widget.kind, pageUrl);
      if (!mounted || request != _request) return;
      setState(() {
        _page = page;
        _loading = false;
      });
      widget.onPageLoaded(pageUrl, page);
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error.toString();
        _verificationError = error is MissavVerificationRequiredException
            ? error
            : null;
        _loading = false;
      });
    }
  }

  Future<void> _verifyAndRetry() async {
    final verification = _verificationError;
    final verifyAccess = widget.verifyAccess;
    if (verification == null || verifyAccess == null || _verifyingAccess) {
      return;
    }
    final request = _request;
    setState(() => _verifyingAccess = true);
    var verified = false;
    try {
      verified = await verifyAccess(context, verification);
    } catch (_) {
      verified = false;
    } finally {
      if (mounted) setState(() => _verifyingAccess = false);
    }
    if (!mounted ||
        !verified ||
        request != _request ||
        verification != _verificationError) {
      return;
    }
    await _load(_requestedUrl);
  }

  Widget _errorView(S s) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _verificationError == null
                ? s.videoLoadFailed
                : s.videoVerificationRequired,
            textAlign: TextAlign.center,
          ),
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              if (_verificationError != null && widget.verifyAccess != null)
                TextButton.icon(
                  onPressed: _verifyingAccess ? null : _verifyAndRetry,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: Text(s.videoVerifyAccess),
                ),
              TextButton(
                onPressed: _loading ? null : () => _load(_requestedUrl),
                child: Text(s.retry),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final page = _page;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BottomSheetHeader(title: widget.title),
        Flexible(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? _errorView(s)
              : page == null || page.links.isEmpty
              ? Center(child: Text(s.noResults))
              : ListView.separated(
                  itemCount: page.links.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final link = page.links[index];
                    return ListTile(
                      key: ValueKey('video-filter-option-${link.url}'),
                      title: Tooltip(
                        message: link.label,
                        child: Text(
                          link.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).pop(link),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              if (page?.previousUrl != null)
                TextButton.icon(
                  onPressed: _loading ? null : () => _load(page!.previousUrl),
                  icon: const Icon(Icons.chevron_left),
                  label: Text(s.previousPage),
                ),
              if (page?.nextUrl != null)
                TextButton.icon(
                  onPressed: _loading ? null : () => _load(page!.nextUrl),
                  icon: const Icon(Icons.chevron_right),
                  label: Text(s.nextPage),
                ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(s.cancel),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
