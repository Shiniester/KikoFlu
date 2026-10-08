import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/history_record.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/recommendation_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:shared_preferences/shared_preferences.dart';

const _currentTag = Tag(id: 1, name: 'Current');
const _preferenceTag = Tag(id: 2, name: 'Preferred');
const _voice = Va(id: 'voice', name: 'Voice');

const _current = Work(
  id: 100,
  title: 'Current work',
  tags: [_currentTag],
  vas: [_voice],
  circleId: 7,
);
const _currentTagWork = Work(
  id: 1,
  title: 'Current tag work',
  tags: [_currentTag],
);
const _preferredWork = Work(
  id: 2,
  title: 'Preferred work',
  tags: [_preferenceTag],
  vas: [_voice],
  circleId: 7,
);
const _preferenceSample = Work(
  id: 99,
  title: 'Preference sample',
  tags: [_preferenceTag],
);

Map<String, dynamic> _json(Work work) =>
    jsonDecode(jsonEncode(work)) as Map<String, dynamic>;

class _Api extends KikoeruApiService {
  final bool authenticated;
  final Completer<Map<String, dynamic>>? reviewCompleter;
  final bool failFirstReview;
  final List<Map<String, dynamic>> playlists;
  final List<Work> candidateWorks;
  final List<String?> reviewFilters = [];
  final reviewRows = <String?, List<Map<String, dynamic>>>{};
  final tagIds = <int>[];
  final List<int> playlistPageSizes = [];
  final List<String> playlistIds = [];
  int reviewFailuresRemaining;
  int directoryCalls = 0;
  int tagCalls = 0;
  int vaCalls = 0;
  int revision = 0;
  String scope;
  Work reviewWork;
  Work playlistWork = _preferenceSample;
  int reviewRating;

  _Api({
    this.authenticated = true,
    this.reviewCompleter,
    this.failFirstReview = false,
    this.playlists = const [],
    List<Work>? candidateWorks,
    Work? reviewWork,
    this.reviewRating = 5,
    required this.scope,
  }) : candidateWorks = candidateWorks ?? [_currentTagWork, _preferredWork],
       reviewWork = reviewWork ?? _preferenceSample,
       reviewFailuresRemaining = failFirstReview ? 1 : 0;

  @override
  bool get hasAuthenticatedAccount => authenticated;

  @override
  String get recommendationPreferenceScope => scope;

  @override
  int get recommendationPreferenceRevision => revision;

  @override
  Future<Map<String, dynamic>> getMyReviews({
    int page = 1,
    int pageSize = 20,
    String? filter,
    String order = 'updated_at',
    String sort = 'desc',
    CancelToken? cancelToken,
  }) async {
    reviewFilters.add(filter);
    if (reviewRows.containsKey(filter)) return {'works': reviewRows[filter]};
    if (filter != null) return {'reviews': []};
    if (reviewFailuresRemaining > 0) {
      reviewFailuresRemaining--;
      throw StateError('temporary review failure');
    }
    if (reviewCompleter != null) return reviewCompleter!.future;
    return {
      'reviews': [
        {'work': _json(reviewWork), 'rating': reviewRating},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getUserPlaylists({
    int page = 1,
    int pageSize = 20,
    String filterBy = 'all',
    CancelToken? cancelToken,
  }) async {
    directoryCalls++;
    playlistPageSizes.add(pageSize);
    return {'playlists': playlists};
  }

  @override
  Future<Map<String, dynamic>> getPlaylistWorks({
    required String playlistId,
    int page = 1,
    int pageSize = 12,
    CancelToken? cancelToken,
  }) async {
    playlistIds.add(playlistId);
    playlistPageSizes.add(pageSize);
    return {
      'works': [_json(playlistWork)],
    };
  }

  @override
  Future<Map<String, dynamic>> getWorksByTag({
    required int tagId,
    int page = 1,
    int pageSize = 40,
    String? order,
    String? sort,
    int? subtitle,
    int? seed,
    CancelToken? cancelToken,
  }) async {
    tagCalls++;
    tagIds.add(tagId);
    return {'works': candidateWorks.map(_json).toList()};
  }

  @override
  Future<Map<String, dynamic>> getWorksByVa({
    required String vaId,
    int page = 1,
    int pageSize = 40,
    String? order,
    String? sort,
    int? subtitle,
    int? seed,
    CancelToken? cancelToken,
  }) async {
    vaCalls++;
    return {'works': candidateWorks.map(_json).toList()};
  }
}

class _Notifier extends RecommendationNotifier {
  _Notifier(
    super.ref,
    super.accessId, {
    Future<List<HistoryRecord>> Function()? historyLoader,
    Future<Set<int>> Function(Iterable<int>)? heardIdsLoader,
  }) : super(
         random: Random(1),
         now: _fixedNow,
         historyLoader: historyLoader ?? _emptyHistory,
         heardIdsLoader: heardIdsLoader ?? _unheard,
       );

  static DateTime _fixedNow() => DateTime.utc(2026, 10, 8);
  static final heardLookups = <Set<int>>[];
  static Future<List<HistoryRecord>> _emptyHistory() async => const [];
  static Future<Set<int>> _unheard(Iterable<int> ids) async {
    heardLookups.add(ids.toSet());
    return const {};
  }
}

List<Map<String, dynamic>> _playlists() => [
  for (var index = 0; index < 3; index++)
    {
      'id': 'playlist-$index',
      'user_name': 'user',
      'privacy': 0,
      'name': 'Playlist $index',
      'updated_at': '2026-10-0${8 - index}T00:00:00Z',
    },
];

ProviderContainer _container(
  _Api api, {
  Future<List<HistoryRecord>> Function()? historyLoader,
  Future<Set<int>> Function(Iterable<int>)? heardIdsLoader,
}) => ProviderContainer(
  overrides: [
    kikoeruApiServiceProvider.overrideWithValue(api),
    recommendationProvider.overrideWith(
      (ref, id) => _Notifier(
        ref,
        id,
        historyLoader: historyLoader,
        heardIdsLoader: heardIdsLoader,
      ),
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'an account switch during history loading starts no old recall',
    () async {
      final history = Completer<List<HistoryRecord>>();
      final started = Completer<void>();
      final api = _Api(scope: 'server|old-user', authenticated: false);
      final container = _container(
        api,
        historyLoader: () {
          started.complete();
          return history.future;
        },
      );
      addTearDown(container.dispose);
      final id = createRecommendationAccessId();
      final subscription = container.listen(
        recommendationProvider(id),
        (_, _) {},
      );
      addTearDown(subscription.close);
      final loading = container
          .read(recommendationProvider(id).notifier)
          .loadRecommendations(_current);
      await started.future;
      api.scope = 'other-server|new-user';
      history.complete([]);
      await loading;
      expect(api.tagCalls, 0);
      expect(api.vaCalls, 0);
      expect(
        container.read(recommendationProvider(id)).recommendations,
        isEmpty,
      );
      expect(container.read(recommendationProvider(id)).isLoading, isFalse);
    },
  );

  test('an account switch during heard lookup discards the old list', () async {
    final heard = Completer<Set<int>>();
    final started = Completer<void>();
    final api = _Api(scope: 'server|old-user', authenticated: false);
    final container = _container(
      api,
      heardIdsLoader: (_) {
        started.complete();
        return heard.future;
      },
    );
    addTearDown(container.dispose);
    final id = createRecommendationAccessId();
    final subscription = container.listen(
      recommendationProvider(id),
      (_, _) {},
    );
    addTearDown(subscription.close);
    final loading = container
        .read(recommendationProvider(id).notifier)
        .loadRecommendations(_current);
    await started.future;
    api.scope = 'other-server|new-user';
    heard.complete({2});
    await loading;
    expect(container.read(recommendationProvider(id)).recommendations, isEmpty);
    expect(container.read(recommendationProvider(id)).isLoading, isFalse);
  });

  test('rare tags win before support votes and tag IDs break ties', () async {
    final api = _Api(
      scope: 'server|anonymous',
      authenticated: false,
      candidateWorks: [
        for (var id = 1; id <= 20; id++) Work(id: id, title: '$id'),
      ],
    );
    final container = _container(
      api,
      historyLoader: () async => [
        HistoryRecord(
          work: const Work(
            id: 999,
            title: 'History',
            tags: [Tag(id: 999, name: 'Common')],
          ),
          lastPlayedTime: DateTime.utc(2026, 10, 8),
        ),
      ],
    );
    addTearDown(container.dispose);
    final id = createRecommendationAccessId();
    final subscription = container.listen(
      recommendationProvider(id),
      (_, _) {},
    );
    addTearDown(subscription.close);
    await container
        .read(recommendationProvider(id).notifier)
        .loadRecommendations(
          const Work(
            id: 100,
            title: 'Current',
            tags: [
              Tag(id: 1, name: 'Common', upvote: 100),
              Tag(id: 5, name: 'Rare five', upvote: 4),
              Tag(id: 3, name: 'Rare three', upvote: 4),
              Tag(id: 2, name: 'Rare two', upvote: 8, downvote: 1),
            ],
          ),
        );
    expect(api.tagIds, [2, 3, 5, 2, 3, 5]);
    expect(api.vaCalls, 0);
    expect(api.reviewFilters, isEmpty);
    expect(api.directoryCalls, 0);
  });

  test(
    'anonymous no-tag recall filters every blocked association and current work',
    () async {
      SharedPreferences.setMockInitialValues({
        'blocked_tags': ['Blocked tag'],
        'blocked_cvs': ['Blocked voice'],
        'blocked_circles': ['Blocked circle'],
      });
      final api = _Api(
        scope: 'server|anonymous',
        authenticated: false,
        candidateWorks: [
          _current,
          const Work(
            id: 1,
            title: 'Blocked tag',
            tags: [Tag(id: 10, name: 'Blocked tag')],
          ),
          const Work(
            id: 2,
            title: 'Blocked voice',
            vas: [Va(id: 'b', name: 'Blocked voice')],
          ),
          const Work(id: 3, title: 'Blocked circle', name: 'Blocked circle'),
          const Work(id: 4, title: 'Available'),
        ],
      );
      final container = _container(api);
      addTearDown(container.dispose);
      final blocksReady = Completer<void>();
      final blockSubscription = container.listen(blockedItemsProvider, (
        _,
        state,
      ) {
        if (state.circles.contains('Blocked circle') &&
            !blocksReady.isCompleted) {
          blocksReady.complete();
        }
      });
      addTearDown(blockSubscription.close);
      await blocksReady.future;
      final id = createRecommendationAccessId();
      final subscription = container.listen(
        recommendationProvider(id),
        (_, _) {},
      );
      addTearDown(subscription.close);
      await container
          .read(recommendationProvider(id).notifier)
          .loadRecommendations(
            const Work(id: 100, title: 'No tags', vas: [_voice]),
          );
      expect(api.tagCalls, 0);
      expect(api.vaCalls, 1);
      expect(
        container
            .read(recommendationProvider(id))
            .recommendations
            .map((work) => work.id),
        [4],
      );
    },
  );

  test(
    'latest low review overrides marks, replay and stale playlist ratings',
    () async {
      final staleWork = Work.fromJson({
        ..._json(_preferredWork),
        'userRating': 5,
        'progress': 'replay',
      });
      final api = _Api(
        scope: 'server|low-review',
        playlists: _playlists(),
        reviewWork: _preferredWork,
        reviewRating: 1,
      )..playlistWork = staleWork;
      api.reviewRows['marked'] = [_json(staleWork)];
      api.reviewRows['replay'] = [_json(staleWork)];
      final container = _container(api);
      addTearDown(container.dispose);
      Future<List<int>> load() async {
        final id = createRecommendationAccessId();
        final subscription = container.listen(
          recommendationProvider(id),
          (_, _) {},
        );
        addTearDown(subscription.close);
        await container
            .read(recommendationProvider(id).notifier)
            .loadRecommendations(_current);
        return container
            .read(recommendationProvider(id))
            .recommendations
            .map((work) => work.id)
            .toList();
      }

      expect(await load(), contains(_preferredWork.id));
      expect(await load(), [_currentTagWork.id]);
    },
  );

  test(
    'four stars, marks and playlist membership use the maximum .8 weight',
    () async {
      final api = _Api(
        scope: 'server|deduplicated-favorite',
        playlists: _playlists(),
        reviewRating: 4,
        candidateWorks: [
          const Work(
            id: 1,
            title: 'Theme',
            tags: [_currentTag],
            rateAverage: 1,
          ),
          _preferredWork,
          for (var id = 3; id <= 20; id++) Work(id: id, title: 'Other $id'),
        ],
      );
      api.reviewRows['marked'] = [_json(_preferenceSample)];
      final container = _container(api);
      addTearDown(container.dispose);
      for (var visit = 0; visit < 2; visit++) {
        final id = createRecommendationAccessId();
        final subscription = container.listen(
          recommendationProvider(id),
          (_, _) {},
        );
        addTearDown(subscription.close);
        await container
            .read(recommendationProvider(id).notifier)
            .loadRecommendations(_current);
        final ids = container
            .read(recommendationProvider(id))
            .recommendations
            .map((work) => work.id)
            .toList();
        // Theme scores 46; the .8 favorite scores 45.36, and summing signals would reverse them.
        expect(ids.take(2), [1, 2]);
        expect(ids, isNot(contains(_preferenceSample.id)));
      }
    },
  );

  test(
    'cold visit stays local; the next access uses the completed profile',
    () async {
      _Notifier.heardLookups.clear();
      final profile = Completer<Map<String, dynamic>>();
      final api = _Api(
        reviewCompleter: profile,
        playlists: _playlists(),
        scope: 'https://server-a|user-a',
      );
      final container = _container(api);
      addTearDown(container.dispose);

      final firstId = createRecommendationAccessId();
      final firstSubscription = container.listen(
        recommendationProvider(firstId),
        (_, _) {},
      );
      addTearDown(firstSubscription.close);
      final firstNotifier = container.read(
        recommendationProvider(firstId).notifier,
      );
      await firstNotifier.loadRecommendations(_current);

      final firstIds = container
          .read(recommendationProvider(firstId))
          .recommendations
          .map((work) => work.id)
          .toList();
      expect(firstIds.first, _currentTagWork.id);
      expect(api.reviewFilters, hasLength(3));
      expect(api.directoryCalls, 1);

      profile.complete({
        'reviews': [
          {'work': _json(_preferenceSample), 'rating': 5},
        ],
      });

      final nextId = createRecommendationAccessId();
      final nextSubscription = container.listen(
        recommendationProvider(nextId),
        (_, _) {},
      );
      addTearDown(nextSubscription.close);
      await container
          .read(recommendationProvider(nextId).notifier)
          .loadRecommendations(_current);

      final nextIds = container
          .read(recommendationProvider(nextId))
          .recommendations
          .map((work) => work.id)
          .toList();
      expect(nextIds.first, _preferredWork.id);
      expect(
        container
            .read(recommendationProvider(firstId))
            .recommendations
            .map((work) => work.id)
            .toList(),
        firstIds,
      );
      expect(api.playlistIds, ['playlist-0', 'playlist-1', 'playlist-2']);
      expect(api.playlistPageSizes.where((size) => size == 12), hasLength(3));
      expect(api.reviewFilters, hasLength(3));
      expect(api.directoryCalls, 1);
      expect(
        api.playlistIds.length + api.directoryCalls + api.reviewFilters.length,
        7,
      );
      expect(_Notifier.heardLookups.last, {1, 2, 99});
    },
  );

  test(
    'failed profile source retries on a later access without losing recalls',
    () async {
      final api = _Api(failFirstReview: true, scope: 'https://server-b|user-b');
      final container = _container(api);
      addTearDown(container.dispose);

      final firstId = createRecommendationAccessId();
      final firstSubscription = container.listen(
        recommendationProvider(firstId),
        (_, _) {},
      );
      addTearDown(firstSubscription.close);
      await container
          .read(recommendationProvider(firstId).notifier)
          .loadRecommendations(_current);
      expect(
        container.read(recommendationProvider(firstId)).recommendations,
        isNotEmpty,
      );

      final nextId = createRecommendationAccessId();
      final nextSubscription = container.listen(
        recommendationProvider(nextId),
        (_, _) {},
      );
      addTearDown(nextSubscription.close);
      await container
          .read(recommendationProvider(nextId).notifier)
          .loadRecommendations(_current);

      expect(api.reviewFilters.where((filter) => filter == null), hasLength(2));
      expect(
        api.reviewFilters.where((filter) => filter == 'marked'),
        hasLength(1),
      );
      expect(
        api.reviewFilters.where((filter) => filter == 'replay'),
        hasLength(1),
      );
      expect(api.directoryCalls, 1);
      expect(
        container.read(recommendationProvider(nextId)).recommendations.first.id,
        _preferredWork.id,
      );
    },
  );

  test(
    'exploration rotates while fixed results stay stable for one work',
    () async {
      final candidates = [
        for (var id = 1; id <= 60; id++)
          Work(id: id, title: 'Candidate $id', tags: const [_currentTag]),
      ];
      final api = _Api(
        candidateWorks: candidates,
        scope: 'https://server-c|user-c',
      );
      final container = _container(api);
      addTearDown(container.dispose);

      final firstId = createRecommendationAccessId();
      final firstSubscription = container.listen(
        recommendationProvider(firstId),
        (_, _) {},
      );
      addTearDown(firstSubscription.close);
      await container
          .read(recommendationProvider(firstId).notifier)
          .loadRecommendations(_current);
      final firstIds = container
          .read(recommendationProvider(firstId))
          .recommendations
          .map((work) => work.id)
          .toList();

      final secondId = createRecommendationAccessId();
      final secondSubscription = container.listen(
        recommendationProvider(secondId),
        (_, _) {},
      );
      addTearDown(secondSubscription.close);
      await container
          .read(recommendationProvider(secondId).notifier)
          .loadRecommendations(_current);
      final secondIds = container
          .read(recommendationProvider(secondId))
          .recommendations
          .map((work) => work.id)
          .toList();

      expect(firstIds.take(12), List.generate(12, (index) => index + 1));
      expect(secondIds.take(12), firstIds.take(12));
      expect(firstIds, hasLength(20));
      expect(secondIds, hasLength(20));
      expect(
        firstIds.skip(12).toSet().intersection(secondIds.skip(12).toSet()),
        isEmpty,
      );
    },
  );

  test(
    'profile refresh after a preference write applies on the next access',
    () async {
      final api = _Api(
        scope: 'https://server-d|user-d',
        reviewWork: _preferredWork,
      );
      final container = _container(api);
      addTearDown(container.dispose);

      Future<List<int>> load(int accessId) async {
        final subscription = container.listen(
          recommendationProvider(accessId),
          (_, _) {},
        );
        addTearDown(subscription.close);
        await container
            .read(recommendationProvider(accessId).notifier)
            .loadRecommendations(_current);
        return container
            .read(recommendationProvider(accessId))
            .recommendations
            .map((work) => work.id)
            .toList();
      }

      final cold = await load(createRecommendationAccessId());
      expect(cold.first, _currentTagWork.id);
      final warmed = await load(createRecommendationAccessId());
      expect(warmed.first, _preferredWork.id);

      api.reviewRating = 1;
      api.revision++;
      final refreshed = await load(createRecommendationAccessId());
      expect(refreshed, [_currentTagWork.id]);
      expect(api.reviewFilters, hasLength(6));
    },
  );

  test('profile cache separates API service and account scopes', () async {
    final firstApi = _Api(scope: 'https://same-server|same-user');
    final firstContainer = _container(firstApi);
    addTearDown(firstContainer.dispose);

    Future<List<int>> load(ProviderContainer container, int accessId) async {
      final subscription = container.listen(
        recommendationProvider(accessId),
        (_, _) {},
      );
      addTearDown(subscription.close);
      await container
          .read(recommendationProvider(accessId).notifier)
          .loadRecommendations(_current);
      return container
          .read(recommendationProvider(accessId))
          .recommendations
          .map((work) => work.id)
          .toList();
    }

    await load(firstContainer, createRecommendationAccessId());
    expect(
      (await load(firstContainer, createRecommendationAccessId())).first,
      _preferredWork.id,
    );

    final pendingProfile = Completer<Map<String, dynamic>>();
    final secondApi = _Api(
      reviewCompleter: pendingProfile,
      scope: 'https://same-server|same-user',
    );
    final secondContainer = _container(secondApi);
    addTearDown(secondContainer.dispose);
    expect(
      (await load(secondContainer, createRecommendationAccessId())).first,
      _currentTagWork.id,
    );

    secondApi.scope = 'https://same-server|different-user';
    expect(
      (await load(secondContainer, createRecommendationAccessId())).first,
      _currentTagWork.id,
    );
    pendingProfile.complete({'reviews': []});
    await load(secondContainer, createRecommendationAccessId());
  });
}
