import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/src/comics/comic_providers.dart';
import 'package:kikoeru_flutter/src/comics/comic_models.dart';
import 'package:kikoeru_flutter/src/comics/comic_images.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/proxy_config.dart';

// Explicit opt-in: these checks contact real sources without account credentials.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final query in ['language:chinese', 'chinese']) {
    test(
      'anonymous live Hitomi search: $query',
      () async {
        HttpOverrides.global = null;
        SharedPreferences.setMockInitialValues({});
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        await ProxyConfig.init();
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final source = container
            .read(comicSourcesProvider)
            .firstWhere((s) => s.key == 'hitomi');
        final result = await source.search(query);
        expect(result.items, isNotEmpty);
        // ignore: avoid_print
        print('hitomi search: ${result.items.length} results');
      },
      skip: Platform.environment['KIKOFLU_LIVE_COMICS'] != '1',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
  for (final key in [
    'picacg',
    'ehentai',
    'jmcomic',
    'hitomi',
    'htmanga',
    'nhentai',
  ]) {
    test(
      'anonymous live source: $key',
      () async {
        HttpOverrides.global = null;
        SharedPreferences.setMockInitialValues({});
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        await ProxyConfig.init();
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final source = container
            .read(comicSourcesProvider)
            .firstWhere((s) => s.key == key);
        try {
          final feed = await source.explore();
          expect(feed.items, isNotEmpty);
          final detail = await source.details(feed.items.first.id);
          final cover = await source.http.bytes(
            detail.cover,
            headers: detail.coverPage.headers,
          );
          final coverCodec = await ui.instantiateImageCodec(cover);
          coverCodec.dispose();
          final chapters = await source.chapters(detail);
          expect(chapters, isNotEmpty);
          final pages = await source.pages(detail, chapters.first);
          expect(pages, isNotEmpty);
          expect(Uri.tryParse(pages.first.url)?.hasAbsolutePath, true);

          if (!pages.first.resolveHtml) {
            final bytes = await source.http.bytes(
              pages.first.url,
              headers: pages.first.headers,
            );
            final decoded =
                pages.first.scrambleId == null ||
                    Uri.parse(
                      pages.first.url,
                    ).path.toLowerCase().endsWith('.gif')
                ? bytes
                : decodeJmImage((
                    bytes,
                    pages.first.url,
                    pages.first.scrambleId!,
                  ));
            final codec = await ui.instantiateImageCodec(decoded);
            codec.dispose();
          }
          // Deliberately log counts only, without titles, image URLs or credentials.
          // ignore: avoid_print
          print(
            '$key: ${feed.items.length} results, ${chapters.length} chapters, ${pages.length} pages',
          );
        } on ComicSourceException catch (error) {
          if (!error.loginRequired || !source.hasAccount) rethrow;
          // Authentication gating is an observed boundary, not a reading pass.
          // ignore: avoid_print
          print('$key: LOGIN_REQUIRED; browsing and reading remain unverified');
        }
      },
      skip: Platform.environment['KIKOFLU_LIVE_COMICS'] != '1',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
