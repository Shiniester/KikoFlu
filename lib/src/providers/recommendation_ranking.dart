import 'dart:math';

import '../models/work.dart';

List<Work> filterPreferredChineseEditions(
  Work current,
  Iterable<Work> candidates,
) {
  final candidateWorks = candidates.toList(growable: false);
  final works = <Work>[current, ...candidateWorks];
  final neighbors = <int, Set<int>>{};
  final languages = <int, List<String>>{};

  for (final work in works) {
    neighbors.putIfAbsent(work.id, () => {});
    final language = work.lang?.trim();
    if (language != null && language.isNotEmpty) {
      languages.putIfAbsent(work.id, () => []).add(language);
    }
    for (final edition in work.otherLanguageEditions ?? const []) {
      neighbors.putIfAbsent(work.id, () => {}).add(edition.id);
      neighbors.putIfAbsent(edition.id, () => {}).add(work.id);
      languages.putIfAbsent(edition.id, () => []).add(edition.lang);
    }
  }

  int? editionRank(int id) {
    final evidence = languages[id] ?? const <String>[];
    if (evidence.isEmpty) return null;
    var best = 3;
    for (final language in evidence) {
      final chineseRank = _chineseLanguageRank(language);
      if (chineseRank != null && chineseRank < best) best = chineseRank;
    }
    return best;
  }

  final checked = <int>{};
  final chineseFamilyIds = <int>{};
  final preferredIds = <int>{};
  for (final start in neighbors.keys) {
    if (!checked.add(start)) continue;
    final family = <int>[];
    final pending = [start];
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      family.add(id);
      for (final neighbor in neighbors[id] ?? const <int>{}) {
        if (checked.add(neighbor)) pending.add(neighbor);
      }
    }

    final chineseRanks = family
        .map(editionRank)
        .whereType<int>()
        .where((rank) => rank < 3)
        .toList(growable: false);
    if (chineseRanks.isEmpty) continue;
    final preferredRank = chineseRanks.reduce((a, b) => a < b ? a : b);
    chineseFamilyIds.addAll(family);
    for (final id in family) {
      if (editionRank(id) == preferredRank) preferredIds.add(id);
    }
  }

  return candidateWorks
      .where((work) => work.id != current.id)
      .where(
        (work) =>
            !chineseFamilyIds.contains(work.id) ||
            preferredIds.contains(work.id),
      )
      .toList(growable: false);
}

int? _chineseLanguageRank(String language) {
  final normalized = language.trim().toLowerCase().replaceAll(
    RegExp(r'[\s-]+'),
    '_',
  );
  if (const {
        'chi_hans',
        'zh_cn',
        'zh_sg',
        'zh_hans',
        'simplified_chinese',
        '简体中文',
        '簡體中文',
        '簡体中文',
        '简体字',
        '簡體字',
      }.contains(normalized) ||
      normalized.startsWith('zh_hans_')) {
    return 0;
  }
  if (const {
        'chi_hant',
        'zh_tw',
        'zh_hk',
        'zh_mo',
        'zh_hant',
        'traditional_chinese',
        '繁体中文',
        '繁體中文',
        '繁体字',
        '繁體字',
      }.contains(normalized) ||
      normalized.startsWith('zh_hant_')) {
    return 1;
  }
  if (const {'chi', 'zh', 'chinese', '中文'}.contains(normalized)) return 2;
  return null;
}

class RecommendationSample {
  final Work work;
  final double weight;

  const RecommendationSample(this.work, this.weight);
}

class RecommendationProfile {
  final List<RecommendationSample> positive;
  final List<Work> negative;
  final Map<int, int> ratings;
  final Set<int> markedIds;
  final Set<int> replayIds;

  const RecommendationProfile({
    this.positive = const [],
    this.negative = const [],
    this.ratings = const {},
    this.markedIds = const {},
    this.replayIds = const {},
  });

  static const empty = RecommendationProfile();
}

class RecommendationHistorySample {
  final Work work;
  final DateTime lastPlayed;

  const RecommendationHistorySample(this.work, this.lastPlayed);
}

Map<int, double> recommendationTagWeights(
  Iterable<Work> candidates, {
  Iterable<Work> relatedWorks = const [],
}) {
  final works = candidates.toList(growable: false);
  final count = <int, int>{};
  final ids = <int>{};
  for (final work in works) {
    final tags = work.tags?.map((tag) => tag.id).toSet() ?? const <int>{};
    ids.addAll(tags);
    for (final id in tags) {
      count.update(id, (value) => value + 1, ifAbsent: () => 1);
    }
  }
  for (final work in relatedWorks) {
    ids.addAll(work.tags?.map((tag) => tag.id) ?? const []);
  }
  return {
    for (final id in ids)
      id: 1 + log((works.length + 1) / ((count[id] ?? 0) + 1)),
  };
}

Map<String, double> recommendationTagNameWeights(
  Iterable<Work> candidates, {
  Iterable<Work> relatedWorks = const [],
}) {
  final works = candidates.toList(growable: false);
  final count = <String, int>{};
  final names = <String>{};
  for (final work in works) {
    final tags = work.tags?.map((tag) => tag.name).toSet() ?? const <String>{};
    names.addAll(tags);
    for (final name in tags) {
      count.update(name, (value) => value + 1, ifAbsent: () => 1);
    }
  }
  for (final work in relatedWorks) {
    names.addAll(work.tags?.map((tag) => tag.name) ?? const []);
  }
  return {
    for (final name in names)
      name: 1 + log((works.length + 1) / ((count[name] ?? 0) + 1)),
  };
}

double weightedTagJaccard(
  Iterable<int> first,
  Iterable<int> second,
  Map<int, double> weights,
) {
  final left = first.toSet();
  final right = second.toSet();
  final union = left.union(right);
  if (union.isEmpty) return 0;
  final intersection = left.intersection(right);
  double weight(int id) => weights[id] ?? 1;
  final denominator = union.fold<double>(0, (sum, id) => sum + weight(id));
  final numerator = intersection.fold<double>(0, (sum, id) => sum + weight(id));
  return numerator / denominator;
}

double _workSimilarity(Work first, Work second, Map<int, double> weights) {
  final tags = weightedTagJaccard(
    first.tags?.map((tag) => tag.id) ?? const [],
    second.tags?.map((tag) => tag.id) ?? const [],
    weights,
  );
  final firstVas = first.vas?.map((va) => va.id).toSet() ?? const <String>{};
  final secondVas = second.vas?.map((va) => va.id).toSet() ?? const <String>{};
  final vas = firstVas.intersection(secondVas).isNotEmpty ? 1.0 : 0.0;
  final circle = first.circleId != null && first.circleId == second.circleId
      ? 1.0
      : 0.0;
  return tags * .8 + vas * .15 + circle * .05;
}

double _workSimilarityByName(
  Work first,
  Work second,
  Map<String, double> weights,
) {
  final firstTags = first.tags?.map((tag) => tag.name) ?? const <String>[];
  final secondTags = second.tags?.map((tag) => tag.name) ?? const <String>[];
  final left = firstTags.toSet();
  final right = secondTags.toSet();
  final union = left.union(right);
  final denominator = union.fold<double>(
    0,
    (sum, name) => sum + (weights[name] ?? 1),
  );
  final tagSimilarity = denominator == 0
      ? 0.0
      : left
                .intersection(right)
                .fold<double>(0, (sum, name) => sum + (weights[name] ?? 1)) /
            denominator;
  final firstVas = first.vas?.map((va) => va.name).toSet() ?? const <String>{};
  final secondVas =
      second.vas?.map((va) => va.name).toSet() ?? const <String>{};
  final vas = firstVas.intersection(secondVas).isNotEmpty ? 1.0 : 0.0;
  final circle = first.name != null && first.name == second.name ? 1.0 : 0.0;
  return tagSimilarity * .8 + vas * .15 + circle * .05;
}

double _maxSimilarity(
  Work candidate,
  Iterable<RecommendationSample> samples,
  Map<int, double> weights,
) {
  var maximum = 0.0;
  for (final sample in samples) {
    maximum = max(
      maximum,
      _workSimilarity(candidate, sample.work, weights) * sample.weight,
    );
  }
  return maximum;
}

double _maxWorkSimilarity(
  Work candidate,
  Iterable<Work> samples,
  Map<int, double> weights,
) {
  var maximum = 0.0;
  for (final sample in samples) {
    maximum = max(maximum, _workSimilarity(candidate, sample, weights));
  }
  return maximum;
}

double recommendationPersonalPreference({
  required Work candidate,
  required RecommendationProfile profile,
  required List<RecommendationHistorySample> history,
  required Map<int, double> tagWeights,
  required Map<String, double> tagNameWeights,
  required DateTime now,
}) {
  final explicitPositive = _maxSimilarity(
    candidate,
    profile.positive,
    tagWeights,
  );
  final explicitNegative = _maxWorkSimilarity(
    candidate,
    profile.negative,
    tagWeights,
  );
  final explicit = explicitPositive - explicitNegative * .25;

  var recent = 0.0;
  for (final sample in history) {
    final ageDays =
        max(0, now.difference(sample.lastPlayed).inSeconds) /
        Duration.secondsPerDay;
    final decay = pow(.5, ageDays / 30).toDouble();
    recent = max(
      recent,
      _workSimilarityByName(candidate, sample.work, tagNameWeights) * decay,
    );
  }
  return explicit * .8 + recent * .2;
}

double recommendationScore({
  required Work current,
  required Work candidate,
  required RecommendationProfile profile,
  required List<RecommendationHistorySample> history,
  required Map<int, double> tagWeights,
  required Map<String, double> tagNameWeights,
  required DateTime now,
  required bool heard,
}) {
  final tags = weightedTagJaccard(
    current.tags?.map((tag) => tag.id) ?? const [],
    candidate.tags?.map((tag) => tag.id) ?? const [],
    tagWeights,
  );
  final sameVa =
      current.vas != null &&
      candidate.vas != null &&
      current.vas!.any(
        (va) => candidate.vas!.any((candidateVa) => candidateVa.id == va.id),
      );
  final sameCircle =
      current.circleId != null &&
      candidate.circleId != null &&
      current.circleId == candidate.circleId;
  return 45 * tags +
      30 *
          recommendationPersonalPreference(
            candidate: candidate,
            profile: profile,
            history: history,
            tagWeights: tagWeights,
            tagNameWeights: tagNameWeights,
            now: now,
          ) +
      (sameVa ? 20 : 0) +
      (sameCircle ? 10 : 0) +
      (candidate.hasSubtitle == true ? 10 : 0) +
      (candidate.rateAverage ?? 0) -
      (heard ? 10 : 0);
}

bool isExplicitlyExcluded(Work candidate, RecommendationProfile profile) {
  final rating = profile.ratings[candidate.id] ?? candidate.userRating;
  return rating != null && rating >= 1 && rating <= 2;
}
