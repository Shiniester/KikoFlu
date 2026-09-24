import 'package:flutter/foundation.dart';

import 'search_type.dart';

enum SearchScope { globalWorks, onlineMarks, history, playlists, downloads }

@immutable
class SearchCondition {
  const SearchCondition({
    required this.id,
    required this.type,
    required this.value,
    this.isExclude = false,
  });

  final String id;
  final SearchType type;
  final String value;
  final bool isExclude;

  String toSearchString() {
    switch (type) {
      case SearchType.keyword:
        return value;
      case SearchType.rjNumber:
        return 'RJ$value';
      case SearchType.tag:
        return isExclude ? '\$-tag:$value\$' : '\$tag:$value\$';
      case SearchType.circle:
        return isExclude ? '\$-circle:$value\$' : '\$circle:$value\$';
      case SearchType.va:
        return isExclude ? '\$-va:$value\$' : '\$va:$value\$';
    }
  }
}

@immutable
class SearchQuery {
  SearchQuery({
    required this.scope,
    required List<SearchCondition> conditions,
    this.minRate = 0,
    this.ageRating = AgeRating.all,
    this.salesRange = SalesRange.all,
    this.progressFilter,
  }) : conditions = List.unmodifiable(conditions);

  final SearchScope scope;
  final List<SearchCondition> conditions;
  final double minRate;
  final AgeRating ageRating;
  final SalesRange salesRange;
  final String? progressFilter;
}
