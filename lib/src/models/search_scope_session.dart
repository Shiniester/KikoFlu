import 'dart:convert';

import 'work.dart';
import 'history_record.dart';
import 'download_task.dart';
import 'search_query.dart';

class ScopedSearchEntry {
  const ScopedSearchEntry({
    required this.work,
    this.historyRecord,
    this.downloadTasks = const [],
    this.playlistNames = const [],
  });

  final Work work;
  final HistoryRecord? historyRecord;
  final List<DownloadTask> downloadTasks;
  final List<String> playlistNames;

  ScopedSearchEntry copyWith({
    Work? work,
    HistoryRecord? historyRecord,
    List<DownloadTask>? downloadTasks,
    List<String>? playlistNames,
  }) => ScopedSearchEntry(
    work: work ?? this.work,
    historyRecord: historyRecord ?? this.historyRecord,
    downloadTasks: downloadTasks ?? this.downloadTasks,
    playlistNames: playlistNames ?? this.playlistNames,
  );
}

/// Keeps fully read source data alive while the user returns to edit a query.
class SearchScopeSession {
  final Map<String, Map<int, ScopedSearchEntry>> _entries = {};
  final Set<String> _completedSources = {};

  String _sourceKey(SearchQuery query, String accountKey) =>
      '${query.scope.name}|$accountKey|${query.progressFilter ?? ''}';

  List<ScopedSearchEntry> entriesFor(SearchQuery query, String accountKey) =>
      List.unmodifiable(
        _entries[_sourceKey(query, accountKey)]?.values ??
            const <ScopedSearchEntry>[],
      );

  bool isComplete(SearchQuery query, String accountKey) =>
      _completedSources.contains(_sourceKey(query, accountKey));

  ScopedSearchEntry add(
    SearchQuery query,
    String accountKey,
    ScopedSearchEntry entry,
  ) {
    final source = _entries.putIfAbsent(
      _sourceKey(query, accountKey),
      () => <int, ScopedSearchEntry>{},
    );
    final previous = source[entry.work.id];
    if (previous == null) {
      source[entry.work.id] = entry;
      return entry;
    }

    final mergedWorkJson = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(previous.work.toJson())) as Map,
    );
    final incomingWorkJson =
        jsonDecode(jsonEncode(entry.work.toJson())) as Map<String, dynamic>;
    for (final field in incomingWorkJson.entries) {
      if (field.value != null) mergedWorkJson[field.key] = field.value;
    }
    final tasks = <String, DownloadTask>{
      for (final task in previous.downloadTasks) task.id: task,
      for (final task in entry.downloadTasks) task.id: task,
    };
    final merged = ScopedSearchEntry(
      work: Work.fromJson(mergedWorkJson),
      historyRecord: entry.historyRecord ?? previous.historyRecord,
      downloadTasks: tasks.values.toList(growable: false),
      playlistNames: <String>{
        ...previous.playlistNames,
        ...entry.playlistNames,
      }.toList(growable: false),
    );
    source[entry.work.id] = merged;
    return merged;
  }

  void markComplete(SearchQuery query, String accountKey) {
    _completedSources.add(_sourceKey(query, accountKey));
  }
}
