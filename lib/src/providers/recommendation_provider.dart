import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/history_record.dart';
import '../models/playlist.dart';
import '../models/work.dart';
import '../services/history_database.dart';
import '../services/kikoeru_api_service.dart' hide kikoeruApiServiceProvider;
import 'auth_provider.dart';
import 'recommendation_ranking.dart';
import 'settings_provider.dart';

class RecommendationState {
  final List<Work> recommendations;
  final bool isLoading;
  final String? error;

  const RecommendationState({
    this.recommendations = const [],
    this.isLoading = false,
    this.error,
  });

  RecommendationState copyWith({
    List<Work>? recommendations,
    bool? isLoading,
    String? error,
  }) {
    return RecommendationState(
      recommendations: recommendations ?? this.recommendations,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

int _nextRecommendationAccessId = 0;

int createRecommendationAccessId() => ++_nextRecommendationAccessId;

class RecommendationNotifier extends StateNotifier<RecommendationState> {
  final Ref ref;
  final int accessId;
  final Random _random;
  final DateTime Function() _now;
  final Future<List<HistoryRecord>> Function()? historyLoader;
  final Future<Set<int>> Function(Iterable<int>)? heardIdsLoader;

  RecommendationNotifier(
    this.ref,
    this.accessId, {
    Random? random,
    DateTime Function()? now,
    this.historyLoader,
    this.heardIdsLoader,
  }) : _random = random ?? Random(),
       _now = now ?? DateTime.now,
       super(const RecommendationState());

  Future<void> loadRecommendations(Work work) async {
    if (state.isLoading) return;
    state = state.copyWith(isLoading: true, error: null);

    final api = ref.read(kikoeruApiServiceProvider);
    final scope = api.recommendationPreferenceScope;
    final revision = api.recommendationPreferenceRevision;
    try {
      // The visit takes one online-profile snapshot before any local or recall awaits.
      final profile = await _preferencesForVisit(api, scope, revision);
      if (!mounted) return;
      if (api.recommendationPreferenceScope != scope) {
        state = const RecommendationState();
        return;
      }

      final localRecords = await _loadRecentHistory();
      if (!mounted) return;
      if (api.recommendationPreferenceScope != scope) {
        state = const RecommendationState();
        return;
      }
      final history = localRecords
          .map(
            (record) => RecommendationHistorySample(
              _withoutSignals(record.work),
              record.lastPlayedTime,
            ),
          )
          .toList(growable: false);
      final blocked = ref.read(blockedItemsProvider);
      final explorationKey = '$scope|${work.id}';
      final previousExploration = Set<int>.of(
        _previousExplorationIds.putIfAbsent(api, () => {})[explorationKey] ??
            const {},
      );
      final selectedTags = _selectSearchTags(work, history, profile);
      final candidates = <Work>[];
      var requested = 0;
      var failed = 0;

      if (selectedTags.isNotEmpty) {
        final results = await Future.wait([
          for (final tag in selectedTags)
            _fetchTag(api, tag.id, order: 'rate_average_2dp'),
          for (final tag in selectedTags)
            _fetchTag(api, tag.id, order: 'release'),
        ]);
        requested += results.length;
        failed += results.where((result) => result.failed).length;
        candidates.addAll(results.expand((result) => result.works));
      }
      if (!mounted) return;
      if (api.recommendationPreferenceScope != scope) {
        state = const RecommendationState();
        return;
      }

      if (_eligibleCandidates(work, candidates, profile, blocked).length < 20) {
        final vas = work.vas?.take(2) ?? const <Va>[];
        final results = await Future.wait([
          for (final va in vas) _fetchVa(api, va.id),
        ]);
        requested += results.length;
        failed += results.where((result) => result.failed).length;
        candidates.addAll(results.expand((result) => result.works));
      }
      if (!mounted) return;
      if (api.recommendationPreferenceScope != scope) {
        state = const RecommendationState();
        return;
      }

      if (_eligibleCandidates(work, candidates, profile, blocked).length < 20) {
        final tagId = _strongestPreferenceTag(profile);
        if (tagId != null) {
          final result = await _fetchTag(api, tagId, order: 'rate_average_2dp');
          requested++;
          if (result.failed) {
            failed++;
          } else {
            candidates.addAll(result.works);
          }
        }
        if (_eligibleCandidates(work, candidates, profile, blocked).length <
            20) {
          candidates.addAll(profile.positive.map((sample) => sample.work));
        }
      }
      if (!mounted) return;
      if (api.recommendationPreferenceScope != scope) {
        state = const RecommendationState();
        return;
      }

      final eligible = _eligibleCandidates(work, candidates, profile, blocked);
      final heard = await _loadHeardIds(
        eligible.map((candidate) => candidate.id),
      );
      if (!mounted) return;
      if (api.recommendationPreferenceScope != scope) {
        state = const RecommendationState();
        return;
      }

      final relatedWorks = <Work>[
        work,
        ...history.map((sample) => sample.work),
        ...profile.positive.map((sample) => sample.work),
        ...profile.negative,
      ];
      final weights = recommendationTagWeights(
        eligible,
        relatedWorks: relatedWorks,
      );
      final nameWeights = recommendationTagNameWeights(
        eligible,
        relatedWorks: relatedWorks,
      );
      final now = _now();
      final ranked =
          [
            for (final candidate in eligible)
              _ScoredWork(
                candidate,
                recommendationScore(
                  current: work,
                  candidate: candidate,
                  profile: profile,
                  history: history,
                  tagWeights: weights,
                  tagNameWeights: nameWeights,
                  now: now,
                  heard: heard.contains(candidate.id),
                ),
              ),
          ]..sort((a, b) {
            final scoreOrder = b.score.compareTo(a.score);
            return scoreOrder != 0
                ? scoreOrder
                : a.work.id.compareTo(b.work.id);
          });

      final fixed = ranked.take(12).toList(growable: false);
      final explorePool = ranked.skip(12).take(48).toList(growable: false);
      final unseen = explorePool
          .where((item) => !previousExploration.contains(item.work.id))
          .toList(growable: false);
      final explored = _weightedSample(unseen, 8);
      if (explored.length < 8) {
        final selectedIds = explored.map((item) => item.work.id).toSet();
        explored.addAll(
          _weightedSample(
            explorePool
                .where((item) => !selectedIds.contains(item.work.id))
                .toList(growable: false),
            8 - explored.length,
          ),
        );
      }
      if (explored.isNotEmpty) {
        _previousExplorationIds.putIfAbsent(api, () => {})[explorationKey] =
            explored.map((item) => item.work.id).toSet();
      }
      state = RecommendationState(
        recommendations: [
          ...fixed.map((item) => item.work),
          ...explored.map((item) => item.work),
        ],
        error: requested > 0 && failed == requested
            ? 'Failed to load recommendation candidates'
            : null,
      );
    } catch (error) {
      if (mounted) {
        state = state.copyWith(isLoading: false, error: error.toString());
      }
    }
  }

  Future<List<HistoryRecord>> _loadRecentHistory() async {
    try {
      return await (historyLoader ??
          (() => HistoryDatabase.instance.getAllHistory(limit: 60)))();
    } catch (_) {
      return const [];
    }
  }

  Future<Set<int>> _loadHeardIds(Iterable<int> ids) async {
    try {
      return await (heardIdsLoader ??
          HistoryDatabase.instance.getPlayedWorkIds)(ids);
    } catch (_) {
      return const {};
    }
  }

  Future<RecommendationProfile> _preferencesForVisit(
    KikoeruApiService api,
    String scope,
    int revision,
  ) async {
    if (!api.hasAuthenticatedAccount) return RecommendationProfile.empty;

    // Existing review and playlist provider state has no account scope stamp.
    // Use the API service's host/account-scoped GET cache for profile sampling.
    final profileEntries = _profileCacheByService.putIfAbsent(api, () => {});
    var entry = profileEntries[scope];
    if (entry == null) {
      entry = _ProfileCacheEntry(revision);
      profileEntries[scope] = entry;
      unawaited(_refreshProfile(api, scope, entry));
      return RecommendationProfile.empty;
    }
    if (entry.revision != revision) {
      entry = _ProfileCacheEntry(revision);
      profileEntries[scope] = entry;
      await _refreshProfile(api, scope, entry);
      return _isCurrentProfile(api, scope, entry)
          ? entry.snapshot()
          : RecommendationProfile.empty;
    }

    final pending = entry.inFlight;
    if (pending != null) await pending;
    if (_isCurrentProfile(api, scope, entry) && !entry.isComplete) {
      await _refreshProfile(api, scope, entry);
    }
    return _isCurrentProfile(api, scope, entry)
        ? entry.snapshot()
        : RecommendationProfile.empty;
  }

  Future<void> _refreshProfile(
    KikoeruApiService api,
    String scope,
    _ProfileCacheEntry entry,
  ) {
    final pending = entry.inFlight;
    if (pending != null) return pending;
    late final Future<void> request;
    request = _requestMissingProfileSources(api, scope, entry).whenComplete(() {
      if (identical(entry.inFlight, request)) entry.inFlight = null;
    });
    entry.inFlight = request;
    return request;
  }

  Future<void> _requestMissingProfileSources(
    KikoeruApiService api,
    String scope,
    _ProfileCacheEntry entry,
  ) async {
    final sources = <String, Future<_SourceResult>>{};
    if (!entry.reviewsLoaded) {
      sources['reviews'] = _safeSource(
        () => api.getMyReviews(page: 1, pageSize: 12),
      );
    }
    if (!entry.markedLoaded) {
      sources['marked'] = _safeSource(
        () => api.getMyReviews(page: 1, pageSize: 12, filter: 'marked'),
      );
    }
    if (!entry.replayLoaded) {
      sources['replay'] = _safeSource(
        () => api.getMyReviews(page: 1, pageSize: 12, filter: 'replay'),
      );
    }
    if (!entry.playlistsLoaded) {
      sources['playlists'] = _safeSource(
        () => api.getUserPlaylists(page: 1, pageSize: 20, filterBy: 'all'),
      );
    }

    final initialResults = await Future.wait(
      sources.entries.map(
        (source) async => MapEntry(source.key, await source.value),
      ),
    );
    if (!_isCurrentProfile(api, scope, entry)) return;
    for (final result in initialResults) {
      final value = result.value;
      if (value.failed) continue;
      switch (result.key) {
        case 'reviews':
          entry.reviews = _parseReviewWorks(value.data!);
          entry.reviewsLoaded = true;
          break;
        case 'marked':
          entry.marked = _parseReviewWorks(value.data!);
          entry.markedLoaded = true;
          break;
        case 'replay':
          entry.replay = _parseReviewWorks(value.data!);
          entry.replayLoaded = true;
          break;
        case 'playlists':
          entry.playlists = _parsePlaylists(value.data!);
          entry.playlistsLoaded = true;
          break;
      }
    }

    if (!_isCurrentProfile(api, scope, entry) || !entry.playlistsLoaded) {
      return;
    }
    final recentPlaylists = [...entry.playlists]
      ..sort((a, b) {
        final dateOrder = _playlistUpdatedAt(
          b,
        ).compareTo(_playlistUpdatedAt(a));
        return dateOrder != 0 ? dateOrder : a.id.compareTo(b.id);
      });
    final topPlaylists = recentPlaylists.take(3).toList(growable: false);
    final missingPlaylists = topPlaylists
        .where((playlist) => !entry.playlistWorks.containsKey(playlist.id))
        .toList(growable: false);
    final playlistResults = await Future.wait([
      for (final playlist in missingPlaylists)
        _safeSource(
          () => api.getPlaylistWorks(
            playlistId: playlist.id,
            page: 1,
            pageSize: 12,
          ),
        ),
    ]);
    if (!_isCurrentProfile(api, scope, entry)) return;
    for (var index = 0; index < playlistResults.length; index++) {
      final result = playlistResults[index];
      if (!result.failed) {
        entry.playlistWorks[missingPlaylists[index].id] = _extractWorks(
          result.data!,
        ).map(_withoutSignals).toList();
      }
    }
  }

  bool _isCurrentProfile(
    KikoeruApiService api,
    String scope,
    _ProfileCacheEntry entry,
  ) =>
      api.hasAuthenticatedAccount &&
      api.recommendationPreferenceScope == scope &&
      api.recommendationPreferenceRevision == entry.revision &&
      identical(_profileCacheByService[api]?[scope], entry);

  Future<_SourceResult> _safeSource(
    Future<Map<String, dynamic>> Function() request,
  ) async {
    try {
      return _SourceResult(await request());
    } catch (_) {
      return const _SourceResult.failed();
    }
  }

  List<Tag> _selectSearchTags(
    Work current,
    List<RecommendationHistorySample> history,
    RecommendationProfile profile,
  ) {
    final tags = current.tags ?? const <Tag>[];
    if (tags.isEmpty) return const [];
    final frequency = <String, double>{};
    for (final sample in history) {
      final ageDays =
          max(0, _now().difference(sample.lastPlayed).inSeconds) /
          Duration.secondsPerDay;
      final decay = pow(.5, ageDays / 30).toDouble();
      for (final name
          in sample.work.tags?.map((tag) => tag.name).toSet() ?? const {}) {
        frequency.update(name, (value) => value + decay, ifAbsent: () => decay);
      }
    }
    for (final sample in profile.positive) {
      for (final name
          in sample.work.tags?.map((tag) => tag.name).toSet() ?? const {}) {
        frequency.update(
          name,
          (value) => value + sample.weight,
          ifAbsent: () => sample.weight,
        );
      }
    }
    for (final sample in profile.negative) {
      for (final name
          in sample.tags?.map((tag) => tag.name).toSet() ?? const {}) {
        frequency.update(name, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    final selected = tags.toList()
      ..sort((a, b) {
        final countOrder = (frequency[a.name] ?? 0).compareTo(
          frequency[b.name] ?? 0,
        );
        if (countOrder != 0) return countOrder;
        final voteOrder = _netVotes(b).compareTo(_netVotes(a));
        return voteOrder != 0 ? voteOrder : a.id.compareTo(b.id);
      });
    return selected.take(3).toList(growable: false);
  }

  int? _strongestPreferenceTag(RecommendationProfile profile) {
    final tags = <int, Tag>{};
    final support = <int, double>{};
    for (final sample in profile.positive) {
      for (final tag in sample.work.tags ?? const <Tag>[]) {
        tags.putIfAbsent(tag.id, () => tag);
        support.update(
          tag.id,
          (value) => value + sample.weight,
          ifAbsent: () => sample.weight,
        );
      }
    }
    if (support.isEmpty) return null;
    final ids = support.keys.toList()
      ..sort((a, b) {
        final supportOrder = support[b]!.compareTo(support[a]!);
        if (supportOrder != 0) return supportOrder;
        final voteOrder = _netVotes(tags[b]!).compareTo(_netVotes(tags[a]!));
        return voteOrder != 0 ? voteOrder : a.compareTo(b);
      });
    return ids.first;
  }

  int _netVotes(Tag tag) => (tag.upvote ?? 0) - (tag.downvote ?? 0);

  List<Work> _eligibleCandidates(
    Work current,
    Iterable<Work> candidates,
    RecommendationProfile profile,
    BlockedItemsState blocked,
  ) {
    final preferredEditions = filterPreferredChineseEditions(
      current,
      candidates,
    );
    final byId = <int, Work>{};
    for (final candidate in preferredEditions) {
      if (candidate.id == current.id ||
          isExplicitlyExcluded(candidate, profile) ||
          _isBlocked(candidate, blocked)) {
        continue;
      }
      byId.putIfAbsent(candidate.id, () => candidate);
    }
    return byId.values.toList(growable: false);
  }

  bool _isBlocked(Work work, BlockedItemsState blocked) =>
      (work.tags?.any((tag) => blocked.tags.contains(tag.name)) ?? false) ||
      (work.vas?.any((va) => blocked.cvs.contains(va.name)) ?? false) ||
      (work.name != null && blocked.circles.contains(work.name));

  List<_ScoredWork> _weightedSample(List<_ScoredWork> pool, int count) {
    final remaining = [...pool];
    final selected = <_ScoredWork>[];
    while (remaining.isNotEmpty && selected.length < count) {
      final totalWeight = remaining.fold<double>(
        0,
        (sum, item) => sum + 1 + max(item.score, 0),
      );
      var cursor = _random.nextDouble() * totalWeight;
      var index = remaining.length - 1;
      for (var i = 0; i < remaining.length; i++) {
        cursor -= 1 + max(remaining[i].score, 0);
        if (cursor < 0) {
          index = i;
          break;
        }
      }
      selected.add(remaining.removeAt(index));
    }
    return selected;
  }

  Future<_FetchResult> _fetchTag(
    KikoeruApiService api,
    int tagId, {
    required String order,
  }) async {
    try {
      final data = await api.getWorksByTag(
        tagId: tagId,
        page: 1,
        pageSize: 12,
        order: order,
        sort: 'desc',
      );
      return _FetchResult(_extractWorks(data));
    } catch (_) {
      return const _FetchResult.failed();
    }
  }

  Future<_FetchResult> _fetchVa(KikoeruApiService api, String vaId) async {
    try {
      final data = await api.getWorksByVa(
        vaId: vaId,
        page: 1,
        pageSize: 12,
        order: 'rate_average_2dp',
        sort: 'desc',
      );
      return _FetchResult(_extractWorks(data));
    } catch (_) {
      return const _FetchResult.failed();
    }
  }

  List<Work> _extractWorks(Map<String, dynamic> response) {
    final raw =
        response['works'] as List? ??
        response['reviews'] as List? ??
        response['data'] as List? ??
        const [];
    final works = <Work>[];
    for (final value in raw) {
      if (value is! Map) continue;
      try {
        final item = Map<String, dynamic>.from(value);
        final json = item['work'] is Map
            ? Map<String, dynamic>.from(item['work'] as Map)
            : item;
        works.add(Work.fromJson(json));
      } catch (_) {
        continue;
      }
    }
    return works;
  }

  List<_ReviewWork> _parseReviewWorks(Map<String, dynamic> response) {
    final raw =
        response['works'] as List? ??
        response['reviews'] as List? ??
        response['data'] as List? ??
        const [];
    final result = <_ReviewWork>[];
    for (final value in raw) {
      if (value is! Map) continue;
      try {
        final item = Map<String, dynamic>.from(value);
        final json = item['work'] is Map
            ? Map<String, dynamic>.from(item['work'] as Map)
            : Map<String, dynamic>.from(item);
        final rating = _intValue(
          item['rating'] ?? item['userRating'] ?? json['userRating'],
        );
        final progress = item['progress'] ?? json['progress'];
        if (rating != null) json['userRating'] = rating;
        if (progress is String) json['progress'] = progress;
        result.add(
          _ReviewWork(
            Work.fromJson(json),
            rating,
            progress is String ? progress : null,
          ),
        );
      } catch (_) {
        continue;
      }
    }
    return result;
  }

  List<Playlist> _parsePlaylists(Map<String, dynamic> response) {
    final raw = response['playlists'] as List? ?? const [];
    final result = <Playlist>[];
    for (final value in raw) {
      if (value is! Map) continue;
      try {
        result.add(Playlist.fromJson(Map<String, dynamic>.from(value)));
      } catch (_) {
        continue;
      }
    }
    return result;
  }

  int? _intValue(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value');

  DateTime _playlistUpdatedAt(Playlist playlist) =>
      DateTime.tryParse(playlist.updatedAt) ??
      DateTime.fromMillisecondsSinceEpoch(0);
}

class _ProfileCacheEntry {
  final int revision;
  bool reviewsLoaded = false;
  bool markedLoaded = false;
  bool replayLoaded = false;
  bool playlistsLoaded = false;
  List<_ReviewWork> reviews = const [];
  List<_ReviewWork> marked = const [];
  List<_ReviewWork> replay = const [];
  List<Playlist> playlists = const [];
  final Map<String, List<Work>> playlistWorks = {};
  Future<void>? inFlight;

  _ProfileCacheEntry(this.revision);

  bool get isComplete {
    if (!reviewsLoaded || !markedLoaded || !replayLoaded || !playlistsLoaded) {
      return false;
    }
    final latest = [...playlists]
      ..sort((a, b) {
        final left =
            DateTime.tryParse(a.updatedAt) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final right =
            DateTime.tryParse(b.updatedAt) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final order = right.compareTo(left);
        return order != 0 ? order : a.id.compareTo(b.id);
      });
    return latest
        .take(3)
        .every((playlist) => playlistWorks.containsKey(playlist.id));
  }

  RecommendationProfile snapshot() {
    final ratings = <int, int>{};
    final allReviewsById = <int, _ReviewWork>{};
    final markedIds = <int>{};
    final replayIds = <int>{};
    for (final review in reviews) {
      allReviewsById[review.work.id] = review;
      if (review.rating != null) ratings[review.work.id] = review.rating!;
    }
    for (final review in marked) {
      allReviewsById.putIfAbsent(review.work.id, () => review);
      if (review.rating != null) {
        ratings.putIfAbsent(review.work.id, () => review.rating!);
      }
      markedIds.add(review.work.id);
    }
    for (final review in replay) {
      allReviewsById.putIfAbsent(review.work.id, () => review);
      if (review.rating != null) {
        ratings.putIfAbsent(review.work.id, () => review.rating!);
      }
      replayIds.add(review.work.id);
    }

    final positive = <int, RecommendationSample>{};
    final negative = <int, Work>{};
    void addPositive(Work work, double weight) {
      final rating = ratings[work.id] ?? work.userRating;
      if (rating != null && rating >= 1 && rating <= 2) return;
      final sample = RecommendationSample(_withoutSignals(work), weight);
      final previous = positive[work.id];
      if (previous == null || sample.weight > previous.weight) {
        positive[work.id] = sample;
      }
    }

    for (final review in allReviewsById.values) {
      final rating = ratings[review.work.id] ?? review.rating;
      if (rating != null && rating >= 1 && rating <= 2) {
        negative[review.work.id] = _withoutSignals(review.work);
      } else if (rating != null && rating >= 4) {
        addPositive(review.work, rating == 5 ? 1 : .8);
      }
      if (review.progress == 'replay' || replayIds.contains(review.work.id)) {
        addPositive(review.work, 1);
      } else if (review.progress == 'marked' ||
          markedIds.contains(review.work.id)) {
        addPositive(review.work, .8);
      }
    }
    for (final review in marked) {
      addPositive(review.work, .8);
    }
    for (final review in replay) {
      addPositive(review.work, 1);
    }
    for (final works in playlistWorks.values) {
      for (final work in works) {
        addPositive(work, .8);
      }
    }

    return RecommendationProfile(
      positive: positive.values.toList(growable: false),
      negative: negative.values.toList(growable: false),
      ratings: ratings,
      markedIds: markedIds,
      replayIds: replayIds,
    );
  }
}

Work _withoutSignals(Work work) {
  final json = (jsonDecode(jsonEncode(work)) as Map<String, dynamic>)
    ..remove('userRating')
    ..remove('progress');
  return Work.fromJson(json);
}

class _ReviewWork {
  final Work work;
  final int? rating;
  final String? progress;

  const _ReviewWork(this.work, this.rating, this.progress);
}

class _SourceResult {
  final Map<String, dynamic>? data;
  final bool failed;

  const _SourceResult(this.data) : failed = false;
  const _SourceResult.failed() : data = null, failed = true;
}

class _FetchResult {
  final List<Work> works;
  final bool failed;

  const _FetchResult(this.works) : failed = false;
  const _FetchResult.failed() : works = const [], failed = true;
}

class _ScoredWork {
  final Work work;
  final double score;

  const _ScoredWork(this.work, this.score);
}

final _profileCacheByService =
    <KikoeruApiService, Map<String, _ProfileCacheEntry>>{};
final _previousExplorationIds = <KikoeruApiService, Map<String, Set<int>>>{};

final recommendationProvider = StateNotifierProvider.autoDispose
    .family<RecommendationNotifier, RecommendationState, int>(
      (ref, accessId) => RecommendationNotifier(ref, accessId),
    );
