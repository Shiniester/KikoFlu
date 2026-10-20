import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/storage_service.dart';
import '../providers/works_provider.dart' show LayoutType;
import 'comic_downloads.dart';
import 'comic_http.dart';
import 'comic_library.dart';
import 'comic_models.dart';
import 'comic_source.dart';
import 'comic_images.dart';
import 'sources/pica_source.dart';
import 'sources/jm_source.dart';
import 'sources/eh_source.dart';
import 'sources/ht_source.dart';
import 'sources/nh_source.dart';
import 'sources/hitomi_source.dart';

final comicSourcesProvider = Provider<List<ComicSource>>((ref) {
  final sources = <ComicSource>[
    PicaSource(ComicHttp('picacg')),
    EhSource(ComicHttp('ehentai')),
    JmSource(ComicHttp('jmcomic')),
    HitomiSource(ComicHttp('hitomi')),
    HtSource(ComicHttp('htmanga')),
    NhSource(ComicHttp('nhentai')),
  ];
  ref.onDispose(() {
    for (final s in sources) {
      s.http.dispose();
    }
  });
  return sources;
});
final comicImageLoaderProvider = Provider<ComicImageLoader>(
  (ref) => readComicImage,
);
final comicLibraryProvider = ChangeNotifierProvider<ComicLibrary>(
  (ref) => ComicLibrary(),
);
final comicDownloadsProvider = ChangeNotifierProvider<ComicDownloads>((ref) {
  final sources = ref.read(comicSourcesProvider);
  return ComicDownloads(
    ref.read(comicLibraryProvider),
    (key) => sources.firstWhere((s) => s.key == key),
  );
});
final comicRemoteFavoritesRevisionProvider = StateProvider<int>((ref) => 0);
final comicSettingsRevisionProvider = StateProvider<int>((ref) => 0);
final comicReaderActiveProvider = StateProvider<bool>((ref) => false);
final comicReadingModeProvider = StateProvider<ComicReadingMode>((ref) {
  final name = StorageService.getString('comic_reading_mode');
  return ComicReadingMode.values.where((v) => v.name == name).firstOrNull ??
      ComicReadingMode.rightToLeft;
});
final comicScreenOrientationProvider = StateProvider<ComicScreenOrientation>((
  ref,
) {
  final name = StorageService.getString('comic_screen_orientation');
  return ComicScreenOrientation.values
          .where((v) => v.name == name)
          .firstOrNull ??
      ComicScreenOrientation.system;
});
final comicSelectedSourceProvider = StateProvider<String>(
  (ref) => StorageService.getString('comic_selected_source') ?? 'picacg',
);
final comicLayoutProvider =
    StateNotifierProvider<ComicLayoutNotifier, LayoutType>(
      (ref) => ComicLayoutNotifier(),
    );

final comicPageSizeProvider = StateNotifierProvider<ComicPageSizeNotifier, int>(
  (ref) => ComicPageSizeNotifier(),
);

final comicCollectionPageOrderProvider =
    StateNotifierProvider<ComicCollectionPageOrderNotifier, List<int>>(
      (ref) => ComicCollectionPageOrderNotifier(),
    );

class ComicPageSizeNotifier extends StateNotifier<int> {
  ComicPageSizeNotifier() : super(_initialPageSize());

  static const preferenceKey = 'comic_page_size_preference';
  static const options = [20, 40, 60, 100];

  static int _initialPageSize() {
    final saved = StorageService.getInt(preferenceKey);
    return options.contains(saved) ? saved! : 40;
  }

  void setPageSize(int pageSize) {
    if (!options.contains(pageSize) || state == pageSize) return;
    state = pageSize;
    unawaited(StorageService.setInt(preferenceKey, pageSize));
  }
}

class ComicLayoutNotifier extends StateNotifier<LayoutType> {
  ComicLayoutNotifier() : super(_initialLayout());

  static const preferenceKey = 'comic_layout_type';
  static const legacyPreferenceKey = 'comic_grid';

  static LayoutType _initialLayout() {
    final saved = StorageService.getString(preferenceKey);
    for (final layout in LayoutType.values) {
      if (layout.name == saved) return layout;
    }
    return StorageService.getBool(legacyPreferenceKey) == false
        ? LayoutType.list
        : LayoutType.bigGrid;
  }

  void set(LayoutType layout) {
    if (state == layout) return;
    state = layout;
    unawaited(StorageService.setString(preferenceKey, layout.name));
  }

  void cycle() {
    set(switch (state) {
      LayoutType.bigGrid => LayoutType.smallGrid,
      LayoutType.smallGrid => LayoutType.list,
      LayoutType.list => LayoutType.bigGrid,
    });
  }
}

class ComicCollectionPageOrderNotifier extends StateNotifier<List<int>> {
  ComicCollectionPageOrderNotifier() : super(_load());

  static const preferenceKey = 'comic_collection_page_order';
  static const defaultOrder = [1, 2, 3];

  static List<int> _load() {
    final saved = StorageService.getString(preferenceKey)?.split(',');
    if (saved == null) return List.unmodifiable(defaultOrder);
    final order = saved.map((value) => int.tryParse(value)).toList();
    if (order.any((page) => page == null)) {
      return List.unmodifiable(defaultOrder);
    }
    final pages = order.cast<int>();
    return _isValid(pages) ? List.unmodifiable(pages) : List.unmodifiable(defaultOrder);
  }

  static bool _isValid(List<int> order) =>
      order.length == defaultOrder.length &&
      order.toSet().length == defaultOrder.length &&
      order.every(defaultOrder.contains);

  void updateOrder(List<int> order) {
    if (!_isValid(order) ||
        order.asMap().entries.every((entry) => state[entry.key] == entry.value)) {
      return;
    }
    state = List.unmodifiable(order);
    unawaited(StorageService.setString(preferenceKey, order.join(',')));
  }

  void restoreDefaults() => updateOrder(defaultOrder);
}

final enabledComicSourcesProvider = Provider<List<ComicSource>>((ref) {
  ref.watch(comicSettingsRevisionProvider);
  return ref
      .watch(comicSourcesProvider)
      .where((s) => StorageService.getBool('comic_${s.key}_enabled') ?? true)
      .toList();
});
