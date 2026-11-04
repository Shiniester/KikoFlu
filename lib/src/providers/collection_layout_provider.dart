import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/persistent_enum_preference.dart';
import 'works_provider.dart' show LayoutType;

final audioLayoutProvider =
    StateNotifierProvider<AudioLayoutNotifier, LayoutType>(
      (ref) => AudioLayoutNotifier(),
    );

class AudioLayoutNotifier extends StateNotifier<LayoutType> {
  AudioLayoutNotifier()
    : _preference = PersistentEnumPreference<LayoutType>(
        key: preferenceKey,
        values: LayoutType.values,
        fallback: LayoutType.bigGrid,
      ),
      super(LayoutType.bigGrid) {
    unawaited(_load());
  }

  static const preferenceKey = 'audio_collection_layout_type';
  final PersistentEnumPreference<LayoutType> _preference;

  Future<void> _load() async {
    final saved = await _preference.load();
    if (mounted && saved != null) state = saved;
  }

  void cycle() {
    final next = switch (state) {
      LayoutType.bigGrid => LayoutType.smallGrid,
      LayoutType.smallGrid => LayoutType.list,
      LayoutType.list => LayoutType.bigGrid,
    };
    set(next);
  }

  void set(LayoutType layout) {
    if (state == layout) return;
    state = layout;
    unawaited(_preference.save(layout));
  }
}
