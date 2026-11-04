import 'package:flutter/material.dart';

import '../video_models.dart';

class VideoCatalogSort extends StatelessWidget {
  const VideoCatalogSort({
    super.key,
    required this.options,
    required this.currentUrl,
    required this.currentPage,
    required this.onSelected,
  });

  final List<VideoLink> options;
  final String currentUrl;
  final int currentPage;
  final ValueChanged<VideoLink> onSelected;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();
    final currentSortBy = _sortBy(currentUrl);
    final current = _catalogKey(currentUrl);
    return SizedBox(
      height: 48,
      child: ListView.separated(
        key: const ValueKey('video-catalog-sort-options'),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        scrollDirection: Axis.horizontal,
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final option = options[index];
          final optionSortBy = _sortBy(option.url);
          final selected = currentSortBy != null && optionSortBy != null
              ? currentSortBy == optionSortBy
              : _catalogKey(option.url) == current;
          return Center(
            child: ChoiceChip(
              label: Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              selected: selected,
              onSelected: selected ? null : (_) => onSelected(option),
            ),
          );
        },
      ),
    );
  }

  String _catalogKey(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final query = Map<String, String>.of(uri.queryParameters)
      ..remove('page')
      ..remove('from');
    final pathSegments = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (currentPage > 1 &&
        pathSegments.isNotEmpty &&
        int.tryParse(pathSegments.last) == currentPage) {
      pathSegments.removeLast();
    }
    final path = pathSegments.isEmpty ? '/' : '/${pathSegments.join('/')}/';
    final sortedQuery = Map<String, String>.fromEntries(
      query.entries.toList()
        ..sort((left, right) => left.key.compareTo(right.key)),
    );
    return uri
        .removeFragment()
        .replace(path: path, queryParameters: sortedQuery)
        .toString();
  }

  String? _sortBy(String url) => Uri.tryParse(url)?.queryParameters['sort_by'];
}
