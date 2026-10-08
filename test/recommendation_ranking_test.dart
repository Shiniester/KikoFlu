import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/recommendation_ranking.dart';

final _now = DateTime.utc(2026, 10, 8);

Work _work(
  int id, {
  List<Tag>? tags,
  List<Va>? vas,
  int? circleId,
  String? name,
  double? rating,
  int? userRating,
  bool? hasSubtitle,
}) => Work(
  id: id,
  title: 'Work $id',
  tags: tags,
  vas: vas,
  circleId: circleId,
  name: name,
  rateAverage: rating,
  userRating: userRating,
  hasSubtitle: hasSubtitle,
);

OtherLanguageEdition _edition(int id, String language) => OtherLanguageEdition(
  id: id,
  lang: language,
  title: 'Edition $id',
  sourceId: 'RJ$id',
  isOriginal: false,
  sourceType: 'RJ',
);

double _score(
  Work current,
  Work candidate, {
  RecommendationProfile profile = RecommendationProfile.empty,
  List<RecommendationHistorySample> history = const [],
  Map<int, double> weights = const {},
  Map<String, double> nameWeights = const {},
  bool heard = false,
}) => recommendationScore(
  current: current,
  candidate: candidate,
  profile: profile,
  history: history,
  tagWeights: weights,
  tagNameWeights: nameWeights,
  now: _now,
  heard: heard,
);

void main() {
  test('tag weights use inverse candidate frequency', () {
    final candidates = [
      _work(
        1,
        tags: const [
          Tag(id: 1, name: 'Common'),
          Tag(id: 2, name: 'Rare'),
        ],
      ),
      _work(2, tags: const [Tag(id: 1, name: 'Common')]),
    ];
    final weights = recommendationTagWeights(candidates);

    expect(weights[1], 1);
    expect(weights[2], closeTo(1 + 0.405465, .00001));
    expect(
      weightedTagJaccard([1, 2], [2], weights),
      closeTo(weights[2]! / (weights[1]! + weights[2]!), .00001),
    );
  });

  test('personal preference and creator matches change one shared score', () {
    const tag = Tag(id: 10, name: 'Calm');
    final current = _work(100);
    final candidate = _work(1, tags: const [tag]);
    final preference = RecommendationProfile(
      positive: [
        RecommendationSample(_work(2, tags: const [tag]), 1),
      ],
    );
    final weights = recommendationTagWeights([candidate]);

    expect(
      _score(current, candidate, profile: preference, weights: weights) -
          _score(current, candidate, weights: weights),
      closeTo(19.2, .00001),
    );
    final currentWithVoice = _work(
      100,
      vas: const [Va(id: 'v', name: 'VA')],
    );
    final sameVoice = _work(
      3,
      vas: const [Va(id: 'v', name: 'VA')],
    );
    final sameCircle = _work(4, circleId: 44);
    final base = _work(5);
    expect(
      _score(currentWithVoice, sameVoice) - _score(currentWithVoice, base),
      20,
    );
    expect(
      _score(_work(100, circleId: 44), sameCircle) -
          _score(_work(100, circleId: 44), base),
      10,
    );
  });

  test('public ratings are raw and missing ratings add zero', () {
    final current = _work(100);
    expect(_score(current, _work(1, rating: 5)), 5);
    expect(_score(current, _work(2)), 0);
    expect(
      _score(current, _work(1, rating: 4.8)) -
          _score(current, _work(2, rating: 4)),
      closeTo(.8, .00001),
    );
  });

  test('subtitle availability adds ten points and can change ranking', () {
    final current = _work(100);
    expect(_score(current, _work(1, hasSubtitle: true)), 10);
    expect(_score(current, _work(2, hasSubtitle: false)), 0);
    expect(_score(current, _work(3)), 0);
    expect(
      _score(current, _work(4, rating: 5)),
      lessThan(_score(current, _work(5, rating: 0, hasSubtitle: true))),
    );
  });

  test('Chinese edition filtering prefers simplified then traditional', () {
    final current = _work(100).copyWith(
      lang: 'JPN',
      otherLanguageEditions: [
        _edition(200, 'CHI_HANS'),
        _edition(300, '繁體中文'),
        _edition(400, 'JPN'),
      ],
    );
    final candidates = [
      _work(200).copyWith(lang: 'zh-cn'),
      _work(300).copyWith(lang: 'CHI_HANT'),
      _work(400).copyWith(lang: 'Japanese'),
    ];

    expect(
      filterPreferredChineseEditions(current, candidates).map((w) => w.id),
      [200],
    );
    expect(
      filterPreferredChineseEditions(
        current.copyWith(
          otherLanguageEditions: [_edition(300, '繁体中文'), _edition(400, 'JPN')],
        ),
        candidates.skip(1),
      ).map((w) => w.id),
      [300],
    );
  });

  test(
    'metadata-only preferred ID filters foreign candidates and allows recall',
    () {
      final current = _work(100).copyWith(
        lang: 'JPN',
        otherLanguageEditions: [
          _edition(200, '簡体中文'),
          _edition(300, '繁體中文'),
          _edition(400, 'JPN'),
        ],
      );
      final candidates = [
        _work(300).copyWith(lang: 'CHI_HANT'),
        _work(400).copyWith(lang: 'JPN'),
      ];
      expect(filterPreferredChineseEditions(current, candidates), isEmpty);

      final recalledSimplified = _work(200).copyWith(
        lang: 'CHI_HANS',
        otherLanguageEditions: [_edition(100, 'JPN')],
      );
      expect(
        filterPreferredChineseEditions(_work(100).copyWith(lang: 'JPN'), [
          recalledSimplified,
        ]).map((work) => work.id),
        [200],
      );
    },
  );

  test('current Chinese edition filters its linked alternatives only', () {
    final current = _work(100).copyWith(
      lang: 'CHI_HANS',
      otherLanguageEditions: [_edition(200, 'CHI_HANT'), _edition(300, 'JPN')],
    );
    const unrelatedSameTitle = Work(id: 400, title: 'Same title', lang: 'JPN');
    expect(
      filterPreferredChineseEditions(current, [
        current,
        _work(200).copyWith(lang: 'CHI_HANT'),
        _work(300).copyWith(lang: 'JPN'),
        unrelatedSameTitle,
      ]).map((work) => work.id),
      [400],
    );
    expect(filterPreferredChineseEditions(_work(101), [unrelatedSameTitle]), [
      unrelatedSameTitle,
    ]);
  });

  test(
    'heard penalty offsets a circle match and strong preference can win',
    () {
      final current = _work(100, circleId: 44);
      expect(_score(current, _work(1, circleId: 44), heard: true), 0);

      const tag = Tag(id: 1, name: 'Favorite');
      final candidate = _work(2, tags: const [tag]);
      final profile = RecommendationProfile(
        positive: [
          RecommendationSample(_work(3, tags: const [tag]), 1),
        ],
      );
      expect(
        _score(_work(100), candidate, profile: profile, heard: true),
        closeTo(9.2, .00001),
      );
    },
  );

  test(
    'low personal ratings override favorite signals; zero and three are neutral',
    () {
      final marked = RecommendationProfile(
        positive: [RecommendationSample(_work(1), .8)],
        ratings: const {1: 2, 2: 0, 3: 3},
      );
      expect(isExplicitlyExcluded(_work(1), marked), isTrue);
      expect(isExplicitlyExcluded(_work(2), marked), isFalse);
      expect(isExplicitlyExcluded(_work(3), marked), isFalse);
      expect(isExplicitlyExcluded(_work(4, userRating: 1), marked), isTrue);
    },
  );

  test('local history compares names across servers and decays by 30 days', () {
    final candidate = _work(1, tags: const [Tag(id: 1, name: 'Quiet')]);
    final history = [
      RecommendationHistorySample(
        _work(99, tags: const [Tag(id: 900, name: 'Quiet')]),
        _now.subtract(const Duration(days: 30)),
      ),
    ];
    final nameWeights = recommendationTagNameWeights(
      [candidate],
      relatedWorks: [history.single.work],
    );
    final personal = recommendationPersonalPreference(
      candidate: candidate,
      profile: RecommendationProfile.empty,
      history: history,
      tagWeights: const {},
      tagNameWeights: nameWeights,
      now: _now,
    );
    expect(personal, closeTo(.08, .00001));
  });
}
