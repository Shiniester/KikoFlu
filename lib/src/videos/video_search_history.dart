import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class VideoSearchHistoryState {
  const VideoSearchHistoryState({
    this.queries = const [],
    this.isLoading = true,
  });

  final List<String> queries;
  final bool isLoading;
}

class VideoSearchHistoryNotifier
    extends StateNotifier<VideoSearchHistoryState> {
  VideoSearchHistoryNotifier() : super(const VideoSearchHistoryState()) {
    _ready = _load();
  }

  static const preferenceKey = 'video_search_history';
  static const maxItems = 20;

  late final Future<void> _ready;

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved =
          preferences.getStringList(preferenceKey) ?? const <String>[];
      if (mounted) {
        state = VideoSearchHistoryState(
          queries: saved.take(maxItems).toList(growable: false),
          isLoading: false,
        );
      }
    } catch (_) {
      if (mounted) state = const VideoSearchHistoryState(isLoading: false);
    }
  }

  Future<void> add(String query) async {
    await _ready;
    final normalized = query.trim();
    if (normalized.isEmpty) return;
    final queries = [
      normalized,
      ...state.queries.where((item) => item != normalized),
    ].take(maxItems).toList(growable: false);
    state = VideoSearchHistoryState(queries: queries, isLoading: false);
    await _save();
  }

  Future<void> remove(String query) async {
    await _ready;
    state = VideoSearchHistoryState(
      queries: state.queries.where((item) => item != query).toList(),
      isLoading: false,
    );
    await _save();
  }

  Future<void> clear() async {
    await _ready;
    state = const VideoSearchHistoryState(queries: [], isLoading: false);
    await _save();
  }

  Future<void> _save() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setStringList(preferenceKey, state.queries);
    } catch (_) {
      // Keep the in-memory history when preferences are unavailable.
    }
  }
}

final videoSearchHistoryProvider =
    StateNotifierProvider<VideoSearchHistoryNotifier, VideoSearchHistoryState>(
      (ref) => VideoSearchHistoryNotifier(),
    );
