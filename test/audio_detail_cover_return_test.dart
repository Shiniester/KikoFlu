import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart' as fs;
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/models/history_record.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/work_cover_prefetch.dart';
import 'package:kikoeru_flutter/src/widgets/enhanced_work_card.dart';
import 'package:kikoeru_flutter/src/widgets/history_work_card.dart';
import 'package:kikoeru_flutter/src/widgets/virtualized_sliver_collection.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_cover_frame.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Auth extends AuthNotifier {
  _Auth() : super(KikoeruApiService()) {
    state = const AuthState(host: 'https://covers.invalid');
  }
  @override
  Future<void> enterAnonymous({String? host}) async {}
}

class _CoverCache extends Fake implements BaseCacheManager {
  _CoverCache(List<int> bytes)
    : file = (MemoryFileSystem().file('/cover.png')..writeAsBytesSync(bytes));
  final fs.File file;
  final resume = Completer<void>();
  bool paused = false;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    if (paused) await resume.future;
    yield FileInfo(
      file,
      FileSource.Cache,
      DateTime.now().add(const Duration(days: 1)),
      url,
    );
  }
}

void main() {
  setUpAll(() {
    CachedNetworkImageProvider.defaultCacheManager = _CoverCache([]);
  });
  for (final kind in ['local', 'remote', 'history']) {
    for (final columns in (kind == 'history' ? [2] : [1, 2, 3])) {
      testWidgets(
        '$kind unselected cover remains painted throughout detail return ($columns columns)',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          await StorageService.initCritical(
            preferences: await SharedPreferences.getInstance(),
          );
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final directory = Directory.systemTemp.createTempSync(
            'detail-covers-',
          );
          final file = File('${directory.path}/cover.png');
          file.writeAsBytesSync(
            img.encodePng(
              img.fill(
                img.Image(width: 80, height: 60),
                color: img.ColorRgb8(0, 180, 0),
              ),
            ),
          );
          File localFile(int id) => File('${directory.path}/$id.png');
          for (var id = 0; id < 3; id++) {
            localFile(id).writeAsBytesSync(file.readAsBytesSync());
          }
          final cache = _CoverCache(file.readAsBytesSync());
          final previousCache = CachedNetworkImageProvider.defaultCacheManager;
          CachedNetworkImageProvider.defaultCacheManager = cache;
          addTearDown(() async {
            if (!cache.resume.isCompleted) cache.resume.complete();
            CachedNetworkImageProvider.defaultCacheManager = previousCache;
            PaintingBinding.instance.imageCache.clear();
            PaintingBinding.instance.imageCache.clearLiveImages();
            await directory.delete(recursive: true);
          });
          final navigator = GlobalKey<NavigatorState>();
          await tester.runAsync(() async {
            for (var id = 0; id < 3; id++) {
              final ImageProvider provider = kind == 'local'
                  ? FileImage(localFile(id))
                  : createWorkCoverImageProvider(
                      work: Work(id: id, title: 'Audio $id'),
                      host: 'https://covers.invalid',
                      token: '',
                      cacheWidth: kind == 'history'
                          ? null
                          : calculateWorkCoverCacheWidth(
                              viewportWidth: 390,
                              devicePixelRatio: 1,
                              crossAxisCount: columns,
                              horizontalPadding: 8,
                              crossAxisSpacing: 8,
                              isListCard: columns == 1,
                            ),
                    );
              final stream = provider.resolve(ImageConfiguration.empty);
              final ready = Completer<void>();
              final listener = ImageStreamListener((_, __) {
                if (!ready.isCompleted) ready.complete();
              }, onError: ready.completeError);
              stream.addListener(listener);
              try {
                await ready.future.timeout(const Duration(seconds: 5));
              } finally {
                stream.removeListener(listener);
              }
            }
          });
          await tester.pumpWidget(
            ProviderScope(
              overrides: [authProvider.overrideWith((ref) => _Auth())],
              child: MaterialApp(
                navigatorKey: navigator,
                theme: ThemeData(platform: TargetPlatform.android),
                localizationsDelegates: S.localizationsDelegates,
                supportedLocales: S.supportedLocales,
                home: Scaffold(
                  body: VirtualizedSliverCollection<int>(
                    items: const [0, 1, 2],
                    itemId: (id) => id,
                    retainedItemCount: 100,
                    layout: columns == 1
                        ? VirtualizedCollectionLayout.list
                        : VirtualizedCollectionLayout.masonry,
                    masonryCrossAxisCount: columns,
                    itemBuilder: (context, id, _) {
                      final work = Work(id: id, title: 'Audio $id');
                      void open() => pushWorkDetailRoute(
                        context,
                        builder: (_) => Scaffold(
                          appBar: AppBar(),
                          body: Center(
                            child: WorkCoverClip(
                              child: Image(
                                image: kind == 'local'
                                    ? FileImage(localFile(id))
                                    : createWorkCoverImageProvider(
                                        work: work,
                                        host: 'https://covers.invalid',
                                        token: '',
                                        cacheWidth: kind == 'history'
                                            ? null
                                            : resolveWorkCoverCacheWidth(
                                                context,
                                                crossAxisCount: columns,
                                                isListCard: columns == 1,
                                              ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                      );
                      return kind == 'history'
                          ? HistoryWorkCard(
                              key: ValueKey(id),
                              record: HistoryRecord(
                                work: work,
                                lastPlayedTime: DateTime(2026),
                              ),
                              onTap: open,
                            )
                          : EnhancedWorkCard(
                              key: ValueKey(id),
                              work: work,
                              crossAxisCount: columns,
                              isListLayout: columns == 1,
                              localCoverPath: kind == 'local'
                                  ? localFile(id).path
                                  : null,
                              onTap: open,
                            );
                    },
                  ),
                ),
              ),
            ),
          );
          final other = find.byKey(const ValueKey(1));
          final imageFinder = find.descendant(
            of: other,
            matching: find.byType(Image),
          );
          await tester.pumpAndSettle();
          final originalState = tester.state(imageFinder);
          final raw = find.descendant(
            of: other,
            matching: find.byType(RawImage),
          );
          expect(tester.widget<RawImage>(raw).image, isNotNull);
          for (final evict in [false, true]) {
            await tester.tap(find.text('Audio 0'));
            await tester.pumpAndSettle();
            if (evict) {
              cache.paused = true;
              // A details cover can evict list covers while their route is offstage.
              PaintingBinding.instance.imageCache.clear();
            }
            navigator.currentState!.pop();
            await tester.pump();
            for (var frame = 0; frame < 30; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
              expect(tester.state(imageFinder), same(originalState));
              expect(raw, findsOneWidget, reason: 'evict=$evict frame=$frame');
              expect(
                tester.widget<RawImage>(raw).image,
                isNotNull,
                reason: 'evict=$evict frame=$frame',
              );
              for (final opacity in tester.widgetList<Opacity>(
                find.descendant(of: other, matching: find.byType(Opacity)),
              )) {
                expect(opacity.opacity, 1, reason: 'evict=$evict frame=$frame');
              }
            }
          }
          cache.resume.complete();
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
