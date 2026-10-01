import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show BaseCacheManager, FileResponse;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/screens/offline_work_detail_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/theme.dart';
import 'package:kikoeru_flutter/src/widgets/offline_file_explorer_widget.dart';

class _NoImageCache extends Fake implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => const Stream.empty();
}

class _Api extends KikoeruApiService {}

class _Auth extends AuthNotifier {
  _Auth() : super(_Api()) {
    state = const AuthState();
  }
}

void main() {
  late BaseCacheManager previousCacheManager;
  setUp(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => Directory.systemTemp.path,
        );
    previousCacheManager = CachedNetworkImageProvider.defaultCacheManager;
    CachedNetworkImageProvider.defaultCacheManager = _NoImageCache();
  });
  tearDown(() {
    CachedNetworkImageProvider.defaultCacheManager = previousCacheManager;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'offline details defer local scan and retain missing-folder state',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'offline-detail-idle-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith((ref) => _Auth()),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
        ],
      );
      addTearDown(container.dispose);
      SharedPreferences.setMockInitialValues({
        'custom_download_path': directory.path,
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );

      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navigator,
            theme: AppTheme.lightTheme(null),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: const Scaffold(body: Text('Home')),
          ),
        ),
      );

      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => OfflineWorkDetailScreen(
            work: const Work(
              id: 800,
              title: 'Offline work',
              circleId: 1,
              name: 'Known circle',
              vas: [Va(id: 'va', name: 'Known VA')],
              tags: [Tag(id: 987654, name: 'Known tag')],
              release: '2026-09-30',
            ),
            localWorkDirPath: '${directory.path}/missing-work-directory',
            fileTree: const [
              {'type': 'audio', 'title': 'track.mp3', 'hash': 'track'},
            ],
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.byType(OfflineFileExplorerWidget, skipOffstage: false),
        findsNothing,
      );
      expect(find.text('Known circle', skipOffstage: false), findsOneWidget);
      expect(find.text('Known VA', skipOffstage: false), findsOneWidget);
      expect(find.text('Known tag', skipOffstage: false), findsOneWidget);
      expect(find.text('2026-09-30', skipOffstage: false), findsOneWidget);
      expect(container.read(fileListControllerProvider).workId, isNull);
      expect(
        find.byType(OfflineWorkDetailScreen, skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('RJ800', skipOffstage: false), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byType(OfflineFileExplorerWidget), findsNothing);
      expect(find.text('Known circle'), findsOneWidget);
      expect(find.text('Known VA'), findsOneWidget);
      expect(container.read(fileListControllerProvider).workId, isNull);
      await tester.pump(const Duration(milliseconds: 351));
      await tester.pump();
      await tester.pump();

      expect(find.byType(OfflineFileExplorerWidget), findsOneWidget);
      expect(find.text('Known VA'), findsOneWidget);
      final l10n = S.of(tester.element(find.byType(OfflineWorkDetailScreen)));
      for (
        var i = 0;
        i < 20 && find.text(l10n.workFolderNotExist).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.scrollUntilVisible(
        find.text(l10n.workFolderNotExist),
        200,
        maxScrolls: 10,
      );
      expect(find.text(l10n.workFolderNotExist), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('offline files publish only after entry is ready', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'offline-detail-publish-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/track.mp3').writeAsBytesSync(const []);
    SharedPreferences.setMockInitialValues({
      'custom_download_path': directory.path,
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith((ref) => _Auth()),
        currentTrackProvider.overrideWith((ref) => Stream.value(null)),
      ],
    );
    addTearDown(container.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.lightTheme(null),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );

    final route = MaterialPageRoute<void>(
      builder: (_) => OfflineWorkDetailScreen(
        work: const Work(id: 801, title: 'Offline files'),
        localWorkDirPath: directory.path,
        fileTree: const [
          {
            'type': 'audio',
            'title': 'track.mp3',
            'localRelativePath': 'track.mp3',
            'hash': 'track-hash',
          },
        ],
      ),
    );
    navigator.currentState!.push(route);
    await tester.pump();
    expect(find.byType(OfflineFileExplorerWidget), findsNothing);
    expect(container.read(fileListControllerProvider).workId, isNull);

    await tester.pump(const Duration(milliseconds: 150));
    expect(container.read(fileListControllerProvider).workId, isNull);
    await tester.pump(route.transitionDuration);
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byType(OfflineFileExplorerWidget),
      250,
      maxScrolls: 20,
    );
    for (
      var i = 0;
      i < 30 && container.read(fileListControllerProvider).workId != 801;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }

    final fileList = container.read(fileListControllerProvider);
    expect(fileList.workId, 801);
    expect(fileList.files, hasLength(1));
    expect((fileList.files.single as Map)['title'], 'track.mp3');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('offline route popped during entry does not publish files', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'offline-detail-pop-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/track.mp3').writeAsBytesSync(const []);
    SharedPreferences.setMockInitialValues({
      'custom_download_path': directory.path,
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith((ref) => _Auth()),
        currentTrackProvider.overrideWith((ref) => Stream.value(null)),
      ],
    );
    addTearDown(container.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.lightTheme(null),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    final route = MaterialPageRoute<void>(
      builder: (_) => OfflineWorkDetailScreen(
        work: const Work(id: 802, title: 'Leaves immediately'),
        localWorkDirPath: directory.path,
        fileTree: const [
          {
            'type': 'audio',
            'title': 'track.mp3',
            'localRelativePath': 'track.mp3',
            'hash': 'track-hash',
          },
        ],
      ),
    );
    navigator.currentState!.push(route);
    await tester.pump();
    navigator.currentState!.pop();
    await tester.pump(route.reverseTransitionDuration);
    await tester.pump();

    expect(container.read(fileListControllerProvider).workId, isNull);
    expect(find.byType(OfflineFileExplorerWidget), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
