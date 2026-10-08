import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart' as fs;
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/recommendation_provider.dart';
import 'package:kikoeru_flutter/src/providers/work_detail_display_provider.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/widgets/enhanced_work_card.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/recommendation_section.dart';

class _Recommendations extends RecommendationNotifier {
  _Recommendations(super.ref, super.accessId);
  int requests = 0;
  void show(List<Work> works) {
    state = RecommendationState(recommendations: works);
  }

  @override
  Future<void> loadRecommendations(Work work) async {
    requests++;
  }
}

class _Auth extends AuthNotifier {
  _Auth() : super(KikoeruApiService()) {
    state = const AuthState(host: 'https://recommendation-covers.invalid');
  }

  @override
  Future<void> enterAnonymous({String? host}) async {}
}

class _CoverCache extends Fake implements BaseCacheManager {
  _CoverCache(List<int> bytes)
    : file = (MemoryFileSystem().file('/cover.png')..writeAsBytesSync(bytes));

  final fs.File file;
  final requested = Completer<void>();
  final keys = <String?>[];

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    keys.add(key);
    if (!requested.isCompleted) requested.complete();
    yield FileInfo(file, FileSource.Cache, DateTime(2100), url);
  }
}

void main() {
  testWidgets('recommendation covers start decoding before scrolling to them', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'recommendation-covers-',
    );
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => directory.path,
    );
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final bytes = img.encodePng(img.Image(width: 400, height: 300));
    final cache = _CoverCache(bytes);
    final previousCache = CachedNetworkImageProvider.defaultCacheManager;
    CachedNetworkImageProvider.defaultCacheManager = cache;
    addTearDown(() async {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      CachedNetworkImageProvider.defaultCacheManager = previousCache;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      await directory.delete(recursive: true);
    });
    const related = [Work(id: 987001, title: 'Related cover')];
    await tester.runAsync(() async {
      await CacheService.imageCacheManager.putFile(
        related.single.getCoverImageUrl(
          'https://recommendation-covers.invalid',
        ),
        bytes,
        key: 'work_cover_${related.single.id}',
        fileExtension: 'image',
      );
    });
    late _Recommendations recommendations;
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith((ref) => _Auth()),
        recommendationProvider.overrideWith(
          (ref, id) => recommendations = _Recommendations(ref, id),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: SizedBox(height: 3000)),
                RecommendationSection(work: Work(id: 9, title: 'Work')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(recommendations.requests, 1);
    recommendations.show(related);
    await tester.pump();
    expect(find.byType(EnhancedWorkCard), findsNothing);
    await tester.runAsync(
      () => cache.requested.future.timeout(const Duration(seconds: 10)),
    );
    expect(cache.keys, contains('work_cover_987001'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'recommendations align with details and use the home two-column cards',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late _Recommendations recommendations;
      final container = ProviderContainer(
        overrides: [
          recommendationProvider.overrideWith(
            (ref, id) => recommendations = _Recommendations(ref, id),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.all(16),
                    sliver: RecommendationSection(
                      work: Work(id: 9, title: 'Work'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      recommendations.show([
        for (var id = 1; id <= 6; id++) Work(id: id, title: 'Related work $id'),
      ]);
      await tester.pump();
      expect(find.byIcon(Icons.recommend_outlined), findsNothing);
      expect(tester.getRect(find.text('Related Works')).left, 16);
      final cards = find.byType(EnhancedWorkCard);
      expect(cards, findsNWidgets(6));
      final first = tester.getRect(cards.at(0));
      final second = tester.getRect(cards.at(1));
      final third = tester.getRect(cards.at(2));
      expect(first.left, 16);
      expect(first.top, second.top);
      expect(second.left - first.right, 8);
      expect(first.width, second.width);
      expect(third.top, greaterThan(first.bottom));
      expect(find.byType(Scrollable), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'hidden recommendations wait; enabled recommendations load offscreen once',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      late _Recommendations recommendations;
      final container = ProviderContainer(
        overrides: [
          recommendationProvider.overrideWith(
            (ref, id) => recommendations = _Recommendations(ref, id),
          ),
        ],
      );
      addTearDown(container.dispose);
      final settings = container.read(workDetailDisplayProvider.notifier);
      await settings.toggleRecommendations();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                controller: scroll,
                slivers: const [
                  SliverToBoxAdapter(child: SizedBox(height: 3000)),
                  RecommendationSection(work: Work(id: 9, title: 'Work')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(recommendations.requests, 0);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(recommendations.requests, 0);
      scroll.jumpTo(0);
      await settings.toggleRecommendations();
      await tester.pump();
      await tester.pump();
      expect(recommendations.requests, 1);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();
      expect(recommendations.requests, 1);
      recommendations.show([const Work(id: 10, title: 'Visit result')]);
      await tester.pump();
      scroll.jumpTo(0);
      await tester.pump();
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await settings.toggleRecommendations();
      await tester.pump();
      await tester.pump();
      await settings.toggleRecommendations();
      await tester.pump();
      await tester.pump();
      expect(recommendations.requests, 1);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(find.text('Visit result'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
