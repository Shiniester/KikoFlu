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

class AutoSearchLastSubtitleQueryNotifier extends StateNotifier<bool> {
  static const preferenceKey = 'auto_search_last_subtitle_query';

  AutoSearchLastSubtitleQueryNotifier()
    : super(StorageService.getBool(preferenceKey) ?? true);

  void setEnabled(bool enabled) {
    if (enabled == state) return;
    state = enabled;
    unawaited(StorageService.setBool(preferenceKey, enabled));
  }
}

final autoSearchLastSubtitleQueryProvider =
    StateNotifierProvider<AutoSearchLastSubtitleQueryNotifier, bool>(
      (ref) => AutoSearchLastSubtitleQueryNotifier(),
    );
