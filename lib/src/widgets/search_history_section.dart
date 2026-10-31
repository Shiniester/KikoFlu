import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../providers/unified_search_history_provider.dart';

class SearchHistorySection extends StatelessWidget {
  const SearchHistorySection({
    super.key,
    required this.entries,
    required this.labelFor,
    required this.onSelect,
    required this.onRemove,
    required this.onClear,
    this.isLoading = false,
    this.canPersist = true,
  });

  final List<UnifiedSearchHistoryEntry> entries;
  final String Function(UnifiedSearchHistoryEntry) labelFor;
  final ValueChanged<UnifiedSearchHistoryEntry> onSelect;
  final ValueChanged<UnifiedSearchHistoryEntry> onRemove;
  final VoidCallback onClear;
  final bool isLoading;
  final bool canPersist;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!canPersist)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              s.searchHistoryNotSaved,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ListTile(
          title: Text(s.searchHistory),
          trailing: entries.isEmpty
              ? null
              : IconButton(
                  tooltip: s.clearSearchHistory,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(s.clearSearchHistory),
                        content: Text(s.clearCurrentSearchHistoryConfirm),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: Text(s.cancel),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.of(context).pop(true),
                            child: Text(s.confirm),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true && context.mounted) onClear();
                  },
                ),
        ),
        if (isLoading)
          const Center(child: CircularProgressIndicator())
        else if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(s.noSearchHistory, textAlign: TextAlign.center),
          )
        else
          for (final entry in entries)
            ListTile(
              leading: const Icon(Icons.history),
              title: Text(
                labelFor(entry),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: entry.payload['legacy'] == true
                  ? Text(s.searchLegacyHistory)
                  : null,
              onTap: () => onSelect(entry),
              trailing: IconButton(
                tooltip: s.delete,
                icon: const Icon(Icons.close),
                onPressed: () => onRemove(entry),
              ),
            ),
      ],
    );
  }
}
