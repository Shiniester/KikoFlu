import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum VideoCardField {
  duration,
  releaseDate,
  subtitleTag,
  uncensoredTag,
  makers,
  labels,
  series,
  directors,
}

const _defaultVisibleFields = {
  VideoCardField.duration,
  VideoCardField.releaseDate,
  VideoCardField.subtitleTag,
  VideoCardField.uncensoredTag,
};

class VideoCardDisplayNotifier extends StateNotifier<Set<VideoCardField>> {
  static const _keyPrefix = 'video_card_display_';

  final Set<String> _dirtyKeys = {};

  VideoCardDisplayNotifier() : super(_defaultVisibleFields) {
    _loadSettings();
  }

  static String _keyFor(VideoCardField field) => '$_keyPrefix${field.name}';

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;

      final loaded = <VideoCardField>{
        for (final field in VideoCardField.values)
          if (prefs.getBool(_keyFor(field)) ??
              _defaultVisibleFields.contains(field))
            field,
      };
      for (final field in VideoCardField.values) {
        if (!_dirtyKeys.contains(_keyFor(field))) continue;
        if (state.contains(field)) {
          loaded.add(field);
        } else {
          loaded.remove(field);
        }
      }
      state = Set.unmodifiable(loaded);
      _dirtyKeys.clear();
    } catch (_) {
      // Keep the defaults when preferences are unavailable.
    }
  }

  Future<void> setVisible(VideoCardField field, bool visible) async {
    final key = _keyFor(field);
    _dirtyKeys.add(key);
    if (state.contains(field) != visible) {
      final next = Set<VideoCardField>.of(state);
      if (visible) {
        next.add(field);
      } else {
        next.remove(field);
      }
      state = Set.unmodifiable(next);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, visible);
    } catch (_) {
      // Keep the in-memory setting when preferences are unavailable.
    }
  }

  Future<void> resetToDefault() async {
    _dirtyKeys.addAll(VideoCardField.values.map(_keyFor));
    state = _defaultVisibleFields;
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final field in VideoCardField.values) {
        await prefs.setBool(_keyFor(field), state.contains(field));
      }
    } catch (_) {
      // Keep the defaults in memory when preferences are unavailable.
    }
  }
}

final videoCardDisplayProvider =
    StateNotifierProvider<VideoCardDisplayNotifier, Set<VideoCardField>>(
      (ref) => VideoCardDisplayNotifier(),
    );
