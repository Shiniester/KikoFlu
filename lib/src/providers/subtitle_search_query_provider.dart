import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/storage_service.dart';

class SubtitleSearchQueryNotifier extends StateNotifier<String> {
  static const preferenceKey = 'subtitle_search_query';

  SubtitleSearchQueryNotifier()
    : super(StorageService.getString(preferenceKey)?.trim() ?? '');

  void setQuery(String query) {
    final normalized = query.trim();
    if (normalized == state) return;
    state = normalized;
    unawaited(
      normalized.isEmpty
          ? StorageService.remove(preferenceKey)
          : StorageService.setString(preferenceKey, normalized),
    );
  }
}

final subtitleSearchQueryProvider =
    StateNotifierProvider<SubtitleSearchQueryNotifier, String>(
      (ref) => SubtitleSearchQueryNotifier(),
    );
