import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/screens/work_detail_screen.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/file_explorer_widget.dart';

class _Api extends KikoeruApiService {
  final metadata = Completer<Map<String, dynamic>>();
  final tracks = Completer<List<dynamic>>();
  @override
  Future<Map<String, dynamic>> getWork(
    int id, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) => metadata.future;
  @override
  Future<List<dynamic>> getWorkTracks(int id, {bool forceRefresh = false}) =>
      tracks.future;
}

class _Auth extends AuthNotifier {
  _Auth() : super(_Api()) {
    state = const AuthState(host: 'https://detail.invalid');
  }
}

void main() {
  testWidgets('HD cover completion does not rebuild the file explorer', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('detail-update-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => directory.path,
    );
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final previousCache = CachedNetworkImageProvider.defaultCacheManager;
    CacheService.installImageCacheManager();
    addTearDown(() async {
      debugOnRebuildDirtyWidget = null;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      CachedNetworkImageProvider.defaultCacheManager = previousCache;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      await directory.delete(recursive: true);
    });
    const work = Work(id: 123, title: 'Work');
    await tester.runAsync(() async {
      await CacheService.imageCacheManager.putFile(
        work.getCoverImageUrl('https://detail.invalid', token: ''),
        img.encodePng(img.Image(width: 400, height: 300)),
        key: 'work_cover_123',
        fileExtension: 'image',
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _Auth()),
          kikoeruApiServiceProvider.overrideWithValue(_Api()),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
        ],
        child: const MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: WorkDetailScreen(work: work),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    var explorerBuilds = 0;
    debugOnRebuildDirtyWidget = (element, built) {
      if (element.widget is FileExplorerWidget) explorerBuilds++;
    };
    await tester.pump(const Duration(milliseconds: 400));
    bool hdVisible() => tester
        .widgetList<Image>(find.byType(Image))
        .any((image) => image.image is FileImage);
    for (var i = 0; i < 100 && !hdVisible(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(hdVisible(), isTrue);
    expect(explorerBuilds, 0);
    debugOnRebuildDirtyWidget = null;
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
