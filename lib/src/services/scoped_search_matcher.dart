import '../models/search_query.dart';
import '../models/search_type.dart';
import '../models/work.dart';
import 'work_id_parser.dart';

bool workNeedsSearchMetadata(Work work, SearchQuery query) {
  if (query.minRate > 0 && work.rateAverage == null) return true;
  if (query.ageRating != AgeRating.all &&
      (work.age == null || work.age!.trim().isEmpty)) {
    return true;
  }
  if (query.salesRange != SalesRange.all && work.dlCount == null) return true;
  for (final condition in query.conditions) {
    switch (condition.type) {
      case SearchType.keyword:
      case SearchType.rjNumber:
        break;
      case SearchType.tag:
        if (work.tags == null) return true;
        break;
      case SearchType.va:
        if (work.vas == null) return true;
        break;
      case SearchType.circle:
        if (work.name == null || work.name!.trim().isEmpty) return true;
    }
  }
  return false;
}

bool? matchesSearchQuery(Work work, SearchQuery query) {
  final matches = <bool?>[
    for (final condition in query.conditions)
      _matchesCondition(work, condition),
  ];
  var hasUnknownCondition = false;

  for (var index = 0; index < query.conditions.length; index++) {
    final condition = query.conditions[index];
    final matched = matches[index];
    if (matched == null) {
      hasUnknownCondition = true;
      continue;
    }
    if (condition.isExclude ? matched : !matched) return false;
  }

  if (query.minRate > 0) {
    if (work.rateAverage == null) return null;
    if (work.rateAverage! < query.minRate) return false;
  }
  if (query.ageRating != AgeRating.all) {
    if (work.age == null || work.age!.trim().isEmpty) return null;
    if (!_matchesAge(work.age, query.ageRating)) return false;
  }
  if (query.salesRange != SalesRange.all) {
    if (work.dlCount == null) return null;
    if (work.dlCount! < query.salesRange.value) return false;
  }
  return hasUnknownCondition ? null : true;
}

bool? _matchesCondition(Work work, SearchCondition condition) {
  final value = condition.value.trim().toLowerCase();
  if (value.isEmpty) return true;
  switch (condition.type) {
    case SearchType.keyword:
      return work.title.toLowerCase().contains(value);
    case SearchType.rjNumber:
      final typedId = condition.value.trim();
      final rjIds = WorkIdParser.extractRJIds(
        typedId.toUpperCase().startsWith('RJ') ? typedId : 'RJ$typedId',
      );
      if (rjIds.isEmpty) return false;
      final expected = int.tryParse(rjIds.first.substring(2));
      if (expected == null) return false;
      final actualIds = WorkIdParser.extractRJIds(work.displayId);
      return actualIds.any(
        (actual) => int.tryParse(actual.substring(2)) == expected,
      );
    case SearchType.tag:
      final tags = work.tags;
      if (tags == null) return null;
      return tags.any((tag) => tag.name.toLowerCase().contains(value));
    case SearchType.va:
      final vas = work.vas;
      if (vas == null) return null;
      return vas.any((va) => va.name.toLowerCase().contains(value));
    case SearchType.circle:
      final name = work.name;
      if (name == null || name.trim().isEmpty) return null;
      return name.toLowerCase().contains(value);
  }
}

bool _matchesAge(String? age, AgeRating rating) {
  final normalized = age?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return false;
  return switch (rating) {
    AgeRating.all => true,
    AgeRating.general =>
      normalized.contains('general') ||
          normalized.contains('全年龄') ||
          normalized == 'all ages',
    AgeRating.r15 => normalized.contains('r15') || normalized.contains('r-15'),
    AgeRating.adult =>
      normalized.contains('adult') ||
          normalized.contains('18') ||
          normalized.contains('成人'),
  };
}
