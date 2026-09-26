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
final comicSelectedSourceProvider = StateProvider<String>(
  (ref) => StorageService.getString('comic_selected_source') ?? 'picacg',
);
final comicLayoutProvider =
    StateNotifierProvider<ComicLayoutNotifier, LayoutType>(
      (ref) => ComicLayoutNotifier(),
    );

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

final enabledComicSourcesProvider = Provider<List<ComicSource>>((ref) {
  ref.watch(comicSettingsRevisionProvider);
  return ref
      .watch(comicSourcesProvider)
      .where((s) => StorageService.getBool('comic_${s.key}_enabled') ?? true)
      .toList();
});
