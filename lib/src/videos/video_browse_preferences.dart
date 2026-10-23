import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/works_provider.dart';
import '../utils/persistent_enum_preference.dart';

class VideoBrowseLayoutNotifier extends StateNotifier<LayoutType> {
  VideoBrowseLayoutNotifier()
    : _preference = PersistentEnumPreference<LayoutType>(
        key: preferenceKey,
        values: LayoutType.values,
        fallback: LayoutType.bigGrid,
      ),
      super(LayoutType.bigGrid) {
    unawaited(_load());
  }

  static const preferenceKey = 'video_layout_type';
  final PersistentEnumPreference<LayoutType> _preference;

  Future<void> _load() async {
    final layout = await _preference.load();
    if (mounted && layout != null) state = layout;
  }

  Future<void> setLayout(LayoutType layout) async {
    if (state == layout) return;
    state = layout;
    await _preference.save(layout);
  }

  Future<void> cycle() => setLayout(switch (state) {
    LayoutType.bigGrid => LayoutType.smallGrid,
    LayoutType.smallGrid => LayoutType.list,
    LayoutType.list => LayoutType.bigGrid,
  });
}

final videoBrowseLayoutProvider =
    StateNotifierProvider<VideoBrowseLayoutNotifier, LayoutType>(
      (ref) => VideoBrowseLayoutNotifier(),
    );
