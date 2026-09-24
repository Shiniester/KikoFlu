import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/persistent_enum_preference.dart';
import 'works_provider.dart' show LayoutType;

enum CollectionLayoutKey { history, playlists, downloads }

final collectionLayoutProvider =
    StateNotifierProvider.family<
      CollectionLayoutNotifier,
      LayoutType,
      CollectionLayoutKey
    >((ref, key) => CollectionLayoutNotifier(key));

class CollectionLayoutNotifier extends StateNotifier<LayoutType> {
  CollectionLayoutNotifier(CollectionLayoutKey key)
    : _preference = PersistentEnumPreference<LayoutType>(
        key: 'collection_${key.name}_layout_type',
        values: LayoutType.values,
        fallback: LayoutType.bigGrid,
      ),
      super(LayoutType.bigGrid) {
    unawaited(_load());
  }

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
