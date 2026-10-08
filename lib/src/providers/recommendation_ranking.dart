import 'dart:math';

import '../models/work.dart';

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
      (candidate.rateAverage ?? 0) -
      (heard ? 10 : 0);
}

bool isExplicitlyExcluded(Work candidate, RecommendationProfile profile) {
  final rating = profile.ratings[candidate.id] ?? candidate.userRating;
  return rating != null && rating >= 1 && rating <= 2;
}
