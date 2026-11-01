import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_slice.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/models/download_task.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/update_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/downloaded_file_state_scanner.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/audio_source_headers.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/ui/work_video_playback_screen.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:kikoeru_flutter/src/videos/video_player_platform.dart';
import 'package:kikoeru_flutter/src/videos/video_providers.dart';
import 'package:kikoeru_flutter/src/widgets/app_navigation_scope.dart';
import 'package:kikoeru_flutter/src/widgets/app_navigation_shell.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';
import 'package:kikoeru_flutter/src/widgets/file_explorer_widget.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:kikoeru_flutter/src/widgets/offline_file_explorer_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _audioTrack = AudioTrack(
  id: 'background-audio',
  title: 'Background audio',
  url: 'https://example.invalid/audio.mp3',
);

class _TestAuth extends StateNotifier<AuthState> implements AuthNotifier {
  _TestAuth([super.state = const AuthState()]);

  void setHost(String host) => state = state.copyWith(host: host);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OnlineVideoTreeApi extends KikoeruApiService {
  _OnlineVideoTreeApi(this.files);

  final List<dynamic> files;

  @override
  Future<List<dynamic>> getWorkTracks(
    int workId, {
    bool forceRefresh = false,
  }) async => files;
}

class _EmptyDownloadRepository extends Fake implements DownloadTaskRepository {
  _EmptyDownloadRepository([this.task]);

  final DownloadTask? task;

  @override
  Stream<DownloadTaskChange> get taskChangesStream => const Stream.empty();

  @override
  DownloadTask? taskById(String taskId) => task?.id == taskId ? task : null;
}

class _GatedVideoLibrary extends VideoLibrary {
  _GatedVideoLibrary({required super.preferences});

  final _ready = Completer<void>();

  void completeInitialization() => _ready.complete();

  @override
  Future<void> initialize() async {
    await _ready.future;
    await super.initialize();
  }
}

class _PlaybackSession implements VideoPlaybackSession {
  final ValueNotifier<VideoPlaybackSnapshot> _snapshot = ValueNotifier(
    const VideoPlaybackSnapshot(),
  );
  VideoStream? lastStream;
  bool failNextLoad = false;
  int loadStreamCount = 0;
  int loadFileCount = 0;
  int playCount = 0;
  int pauseCount = 0;
  int disposeCount = 0;
  String? lastFilePath;

  @override
  ValueListenable<VideoPlaybackSnapshot> get snapshot => _snapshot;

  @override
  Widget buildSurface({required double aspectRatio}) =>
      const ColoredBox(color: Colors.black);

  @override
  Future<void> loadStream(
    VideoStream stream, {
    required Duration position,
    required double volume,
  }) async {
    loadStreamCount++;
    lastStream = stream;
    if (failNextLoad) {
      failNextLoad = false;
      throw StateError('controlled load failure');
    }
    _snapshot.value = _snapshot.value.copyWith(
      position: position,
      buffering: false,
      clearError: true,
    );
  }

  @override
  Future<void> loadFile(
    String path, {
    required Duration position,
    required double volume,
  }) async {
    loadFileCount++;
    lastFilePath = path;
    _snapshot.value = _snapshot.value.copyWith(
      position: position,
      buffering: false,
      clearError: true,
    );
  }

  @override
  Future<void> play() async {
    playCount++;
    _snapshot.value = _snapshot.value.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _snapshot.value = _snapshot.value.copyWith(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    _snapshot.value = _snapshot.value.copyWith(position: position);
  }

  @override
  Future<void> setRate(double rate) async {
    _snapshot.value = _snapshot.value.copyWith(rate: rate);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> selectAudioTrack(String id) async {}

  @override
  Future<void> selectSubtitleTrack(String id) async {}

  @override
  Future<void> dispose() async {
    disposeCount++;
    _snapshot.dispose();
  }
}

class _TabHost extends StatelessWidget {
  const _TabHost({
    required this.navigation,
    required this.openWorkVideo,
    required this.openCatalogVideo,
  });

  final AppNavigationController navigation;
  final ValueChanged<BuildContext> openWorkVideo;
  final ValueChanged<BuildContext> openCatalogVideo;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: navigation,
    builder: (context, _) => IndexedStack(
      index: navigation.selectedIndex,
      children: [
        for (var index = 0; index < appTabCount; index++)
          Navigator(
            key: navigation.tabNavigatorKey(index),
            observers: [navigation.tabObserver(index)],
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => switch (index) {
                appAudioTabIndex => _TabHome(
                  buttonText: 'Open work video',
                  onPressed: () => openWorkVideo(context),
                ),
                appVideoTabIndex => _TabHome(
                  buttonText: 'Open catalog video',
                  onPressed: () => openCatalogVideo(context),
                ),
                _ => Scaffold(body: Center(child: Text('Tab $index'))),
              },
            ),
          ),
      ],
    ),
  );
}

class _TabHome extends StatelessWidget {
  const _TabHome({required this.buttonText, required this.onPressed});

  final String buttonText;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(onPressed: onPressed, child: Text(buttonText)),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets(
    'work video playback stays on audio stack, restores platform ownership, and uses manual fullscreen',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        tester.view
          ..physicalSize = const Size(640, 360)
          ..devicePixelRatio = 1
          ..padding = const FakeViewPadding(top: 24, bottom: 24)
          ..viewPadding = const FakeViewPadding(top: 24, bottom: 24);
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({
          'video_player_v1_auto_fullscreen': true,
        });

        const mediaChannel = MethodChannel('test/work-video-platform');
        const pipChannel = MethodChannel('test/work-video-pip');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final platformCalls = <String>[];
        messenger.setMockMethodCallHandler(mediaChannel, (call) async {
          platformCalls.add(call.method);
          if (call.method == 'initialize') {
            return {'brightness': false, 'pictureInPicture': false};
          }
          return null;
        });
        messenger.setMockMethodCallHandler(pipChannel, (_) async => null);
        messenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (_) async => null,
        );
        addTearDown(() {
          messenger.setMockMethodCallHandler(mediaChannel, null);
          messenger.setMockMethodCallHandler(pipChannel, null);
          messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        });

        final preferences = await SharedPreferences.getInstance();
        final library = _GatedVideoLibrary(preferences: preferences);
        final navigation = AppNavigationController();
        addTearDown(navigation.dispose);
        final workSession = _PlaybackSession()..failNextLoad = true;
        final catalogSession = _PlaybackSession();
        final workPlatform = VideoPlayerPlatform(
          channel: mediaChannel,
          pictureInPictureChannel: pipChannel,
          platform: TargetPlatform.android,
        );
        final catalogPlatform = VideoPlayerPlatform(
          channel: mediaChannel,
          pictureInPictureChannel: pipChannel,
          platform: TargetPlatform.android,
        );
        final accountHeaders = {
          'Cookie': 'controlled-account-cookie',
          'X-Test-Auth': 'controlled-header',
        };
        final workStream = VideoStream(
          label: 'clip.mp4',
          url: 'https://server.test/api/media/clip.mp4',
          headers: sourceAwareMediaHeaders(42, accountHeaders: accountHeaders),
        );
        const catalogStream = VideoStream(
          label: 'catalog.mp4',
          url: 'https://catalog.test/video.mp4',
        );
        final s = await S.delegate.load(const Locale('en'));

        Widget workPage() => WorkVideoPlaybackScreen(
          videoId: workVideoPlaybackId(
            sourceIdentity: workVideoSourceIdentity(
              workId: 42,
              host: 'https://server.test/kikoeru',
            ),
            workId: 42,
            fileIdentity: 'Disc 1/clip.mp4',
          ),
          fileName: 'clip.mp4',
          folderPath: 'Disc 1',
          streams: [workStream],
          sessionFactory: () => workSession,
          platform: workPlatform,
        );
        void openWorkVideo(BuildContext context) {
          unawaited(pushBottomDockRoute(context, builder: (_) => workPage()));
        }

        void openCatalogVideo(BuildContext context) {
          unawaited(
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('Catalog video')),
                  body: VideoPlaybackPanel(
                    videoId: 'catalog-video',
                    library: library,
                    title: 'Catalog video',
                    autoPlayOnStart: true,
                    streams: const [catalogStream],
                    sessionFactory: () => catalogSession,
                    platform: catalogPlatform,
                  ),
                ),
              ),
            ),
          );
        }

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authProvider.overrideWith((ref) => _TestAuth()),
              videoLibraryProvider.overrideWith((ref) => library),
              currentTrackProvider.overrideWith(
                (ref) => Stream.value(_audioTrack),
              ),
              positionProvider.overrideWith(
                (ref) => Stream.value(const Duration(seconds: 30)),
              ),
              durationProvider.overrideWith(
                (ref) => Stream.value(const Duration(minutes: 4)),
              ),
              playerStateProvider.overrideWith(
                (ref) => Stream.value(PlayerState(true, ProcessingState.ready)),
              ),
              queueProvider.overrideWith((ref) => Stream.value([_audioTrack])),
              manualSkipAvailabilityProvider.overrideWith(
                (ref) => Stream.value(ManualSkipAvailability.unavailable),
              ),
              audioSliceStateProvider.overrideWith(
                (ref) => const Stream<AudioSliceState>.empty(),
              ),
              isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
              lyricAutoLoaderProvider.overrideWith((ref) {}),
              showUpdateRedDotProvider.overrideWith((ref) => false),
            ],
            child: MaterialApp(
              locale: const Locale('en'),
              supportedLocales: S.supportedLocales,
              localizationsDelegates: S.localizationsDelegates,
              navigatorObservers: [navigation],
              builder: (context, child) =>
                  AppNavigationShell(controller: navigation, child: child!),
              home: _TabHost(
                navigation: navigation,
                openWorkVideo: openWorkVideo,
                openCatalogVideo: openCatalogVideo,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Open work video'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        final workScreen = find.byType(WorkVideoPlaybackScreen);
        expect(
          find.descendant(
            of: workScreen,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        library.completeInitialization();
        await tester.pumpAndSettle();
        expect(find.text(s.videoPlaybackFailed), findsOneWidget);
        expect(find.text(s.videoOpenSource), findsNothing);
        expect(workSession.loadStreamCount, 1);

        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byTooltip(s.retry),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed!
            .call();
        await tester.pumpAndSettle();
        await tester.pumpAndSettle();
        expect(workSession.loadStreamCount, 2);
        expect(workSession.playCount, 1);
        expect(workSession.lastStream?.headers, accountHeaders);
        expect(find.text('clip.mp4'), findsNWidgets(2));
        expect(find.text('Disc 1'), findsOneWidget);
        expect(find.byType(MiniPlayer), findsOneWidget);
        expect(find.byType(AppBar), findsOneWidget);
        expect(
          tester.getSize(find.byType(VideoPlaybackPanel)).width,
          greaterThanOrEqualTo(320),
        );
        expect(find.byTooltip(s.videoFullscreen), findsOneWidget);
        final fullscreenControl = find.byTooltip(s.videoFullscreen);
        final playerRect = tester.getRect(find.byType(VideoPlaybackPanel));
        final fullscreenRect = tester.getRect(fullscreenControl);
        expect(
          fullscreenRect.left >= playerRect.left &&
              fullscreenRect.top >= playerRect.top &&
              fullscreenRect.right <= playerRect.right &&
              fullscreenRect.bottom <= playerRect.bottom,
          isTrue,
        );

        await tester.tap(fullscreenControl);
        await tester.pumpAndSettle();
        expect(find.byType(AppBar), findsNothing);
        expect(
          find.byKey(const ValueKey('work-video-screen-safe-area')),
          findsNothing,
        );
        expect(workSession.loadStreamCount, 2);
        expect(workSession.disposeCount, 0);

        await tester.tap(find.byTooltip(s.videoFullscreen));
        await tester.pumpAndSettle();
        expect(find.byType(AppBar), findsOneWidget);
        expect(
          find.byKey(const ValueKey('work-video-screen-safe-area')),
          findsOneWidget,
        );

        await preferences.setBool('video_player_v1_auto_fullscreen', false);
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationRail),
            matching: find.byIcon(Icons.video_library_outlined),
          ),
        );
        await tester.pumpAndSettle();
        expect(workSession.pauseCount, greaterThan(0));
        expect(workSession.disposeCount, 0);
        expect(
          find.byType(WorkVideoPlaybackScreen, skipOffstage: false),
          findsOneWidget,
        );

        await tester.tap(find.text('Open catalog video'));
        await tester.pumpAndSettle();
        expect(catalogSession.playCount, 1);
        expect(
          platformCalls.where((call) => call == 'initialize'),
          hasLength(2),
        );

        await tester.tap(
          find.descendant(
            of: find.byType(NavigationRail),
            matching: find.byIcon(Icons.library_music_outlined),
          ),
        );
        await tester.pumpAndSettle();
        for (
          var frame = 0;
          frame < 20 &&
              platformCalls.where((call) => call == 'initialize').length < 3;
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          platformCalls.where((call) => call == 'initialize'),
          hasLength(3),
        );
        expect(catalogSession.pauseCount, greaterThan(0));
        expect(workSession.disposeCount, 0);
        expect(find.byType(WorkVideoPlaybackScreen), findsOneWidget);

        await tester.tap(
          find.descendant(
            of: find.byType(NavigationRail),
            matching: find.byIcon(Icons.video_library_outlined),
          ),
        );
        await tester.pumpAndSettle();
        for (
          var frame = 0;
          frame < 20 &&
              platformCalls.where((call) => call == 'initialize').length < 4;
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          platformCalls.where((call) => call == 'initialize'),
          hasLength(4),
        );
        expect(catalogSession.playCount, 1);
        expect(catalogSession.snapshot.value.playing, isFalse);
        expect(workSession.snapshot.value.playing, isFalse);

        expect(tester.takeException(), isNull);

        await tester.tap(
          find.descendant(
            of: find.byType(NavigationRail),
            matching: find.byIcon(Icons.library_music_outlined),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.arrow_back).first);
        await tester.pumpAndSettle();
        expect(find.text('Open work video'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(workSession.disposeCount, 1);
        expect(catalogSession.disposeCount, 1);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  test('work video identities preserve server base paths and isolate files', () {
    final sourceA = workVideoSourceIdentity(
      workId: 42,
      host: 'HTTPS://Server.test/ASMR',
    );
    expect(
      workVideoSourceIdentity(workId: 42, host: 'https://server.test/ASMR/'),
      sourceA,
    );
    expect(
      workVideoSourceIdentity(workId: 42, host: 'https://server.test/asmr'),
      isNot(sourceA),
    );
    expect(
      workVideoPlaybackId(
        sourceIdentity: sourceA,
        workId: 42,
        fileIdentity: 'Disc 1/clip.mp4',
      ),
      isNot(
        workVideoPlaybackId(
          sourceIdentity: sourceA,
          workId: 42,
          fileIdentity: 'Disc 2/clip.mp4',
        ),
      ),
    );
    expect(
      workVideoSourceIdentity(
        workId: 42,
        localPath: '/downloads/clip.mp4',
        downloadUrl:
            'https://server.test/ASMR/api/media/download/clip/clip.mp4?token=test',
      ),
      sourceA,
    );
    expect(
      workVideoSourceIdentity(
        workId: 42,
        localPath: '/downloads/clip.mp4',
        downloadUrl: 'https://server.test/ASMR/api/media/stream/clip',
      ),
      sourceA,
    );
    expect(
      workVideoSourceIdentity(
        workId: 42,
        localPath: '/downloads/clip.mp4',
        host: 'https://other.test',
      ),
      'local:/downloads/clip.mp4',
    );
    expect(
      workVideoSourceIdentity(
        workId: -42,
        host: 'https://other.test',
        localPath: '/downloads/clip.mp4',
      ),
      'jp-asmr',
    );
    expect(
      sourceAwareMediaHeaders(
        -42,
        accountHeaders: const {'Cookie': 'must-not-forward'},
      ),
      isNot(contains('Cookie')),
    );
  });

  testWidgets('work video player loads a local file path', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      SharedPreferences.setMockInitialValues({});
      const mediaChannel = MethodChannel('test/work-video-local-platform');
      const pipChannel = MethodChannel('test/work-video-local-pip');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(mediaChannel, (call) async {
        if (call.method == 'initialize') {
          return {'brightness': false, 'pictureInPicture': false};
        }
        return null;
      });
      messenger.setMockMethodCallHandler(pipChannel, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(mediaChannel, null);
        messenger.setMockMethodCallHandler(pipChannel, null);
      });

      final library = VideoLibrary(
        preferences: await SharedPreferences.getInstance(),
      );
      await library.initialize();
      final session = _PlaybackSession();
      final platform = VideoPlayerPlatform(
        channel: mediaChannel,
        pictureInPictureChannel: pipChannel,
        platform: TargetPlatform.android,
      );
      const localPath = r'C:\offline\clip.mp4';

      await tester.pumpWidget(
        ProviderScope(
          overrides: [videoLibraryProvider.overrideWith((ref) => library)],
          child: MaterialApp(
            locale: const Locale('en'),
            supportedLocales: S.supportedLocales,
            localizationsDelegates: S.localizationsDelegates,
            home: WorkVideoPlaybackScreen(
              videoId: 'work:asmr-one:42:Disc%201%2Fclip.mp4',
              fileName: 'clip.mp4',
              folderPath: '',
              localPath: localPath,
              sessionFactory: () => session,
              platform: platform,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(session.loadFileCount, 1);
      expect(session.lastFilePath, localPath);
      expect(session.loadStreamCount, 0);
      expect(session.playCount, 1);
      expect(find.text('Root'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final downloadStatus in [
    DownloadStatus.completed,
    DownloadStatus.paused,
    null,
  ]) {
    testWidgets(
      'offline video resumes after switching servers ($downloadStatus)',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'kikoflu-offline-video-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final workDirectory = Directory(p.join(directory.path, '42'));
        final videoFile = File(p.join(workDirectory.path, 'Disc 1', 'clip.mp4'))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(const [0]);
        SharedPreferences.setMockInitialValues({
          'custom_download_path': directory.path,
        });
        final preferences = await SharedPreferences.getInstance();
        await StorageService.initCritical(preferences: preferences);
        final library = _GatedVideoLibrary(preferences: preferences);
        final tree = [
          {
            'type': 'folder',
            'title': 'Disc 1',
            'children': [
              {'type': 'video', 'title': 'clip.mp4', 'hash': 'clip-hash'},
            ],
          },
        ];
        final task = DownloadTask(
          id: DownloadTask.createId(
            workId: 42,
            hash: 'clip-hash',
            fileName: 'Disc 1/clip.mp4',
          ),
          workId: 42,
          workTitle: 'Offline work',
          fileName: 'Disc 1/clip.mp4',
          downloadUrl:
              'https://first.test/api/media/download/clip-hash/clip.mp4',
          hash: 'clip-hash',
          status: DownloadStatus.completed,
          createdAt: DateTime(2024),
        );
        var onlineUsesLocal = false;
        final container = ProviderContainer(
          overrides: [
            kikoeruApiServiceProvider.overrideWithValue(
              _OnlineVideoTreeApi(tree),
            ),
            authProvider.overrideWith(
              (ref) => _TestAuth(
                const AuthState(
                  host: 'https://first.test',
                  token: 'test-token',
                ),
              ),
            ),
            downloadServiceProvider.overrideWithValue(
              _EmptyDownloadRepository(
                downloadStatus == null
                    ? null
                    : task.copyWith(status: downloadStatus),
              ),
            ),
            downloadedFileStateScannerProvider.overrideWithValue(
              DownloadedFileStateScanner(
                resolveDownloadedPath: (_, __) async =>
                    onlineUsesLocal ? videoFile.path : null,
                downloadRootPath: () async => directory.path,
                fileExists: (path) async =>
                    onlineUsesLocal && File(path).existsSync(),
              ),
            ),
            videoLibraryProvider.overrideWith((ref) => library),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: const Locale('en'),
              supportedLocales: S.supportedLocales,
              localizationsDelegates: S.localizationsDelegates,
              home: Scaffold(
                body: CustomScrollView(
                  slivers: [
                    OfflineFileExplorerWidget(
                      work: const Work(id: 42, title: 'Offline work'),
                      fileTree: tree,
                      localWorkDirPath: workDirectory.path,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        final videoTab = find.byKey(const ValueKey('work-resource-videos-tab'));
        for (
          var frame = 0;
          frame < 200 && videoTab.evaluate().isEmpty;
          frame++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(videoFile.existsSync(), isTrue);
        expect(videoTab, findsOneWidget);
        await tester.tap(videoTab);
        await tester.pumpAndSettle();
        final videoRow = find.byKey(
          const ValueKey('work-video-Disc 1/clip.mp4'),
        );
        expect(videoRow, findsOneWidget);
        await tester.tap(videoRow);
        final screen = find.byType(WorkVideoPlaybackScreen);
        for (var frame = 0; frame < 100 && screen.evaluate().isEmpty; frame++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 350));
        expect(screen, findsOneWidget);
        expect(
          find.descendant(
            of: screen,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        final playbackPage = tester.widget<WorkVideoPlaybackScreen>(screen);
        expect(playbackPage.folderPath, 'Disc 1');
        expect(playbackPage.localPath, videoFile.path);
        if (downloadStatus != DownloadStatus.completed) {
          expect(
            playbackPage.videoId,
            workVideoPlaybackId(
              sourceIdentity: 'local:${videoFile.path}',
              workId: 42,
              fileIdentity: 'Disc 1/clip.mp4',
            ),
          );
        }
        final positions = VideoLibrary(preferences: preferences);
        addTearDown(positions.dispose);
        const savedPosition = Duration(seconds: 42);
        await positions.savePosition(playbackPage.videoId, savedPosition);

        Navigator.of(tester.element(screen)).pop();
        await tester.pumpAndSettle();
        (container.read(authProvider.notifier) as _TestAuth).setHost(
          'https://second.test',
        );
        await tester.tap(videoRow);
        for (var frame = 0; frame < 100 && screen.evaluate().isEmpty; frame++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 350));
        final reopenedPage = tester.widget<WorkVideoPlaybackScreen>(screen);
        expect(positions.positionFor(reopenedPage.videoId), savedPosition);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();

        (container.read(authProvider.notifier) as _TestAuth).setHost(
          'https://first.test',
        );
        for (final useLocal in [
          if (downloadStatus == DownloadStatus.completed) false,
          true,
        ]) {
          onlineUsesLocal = useLocal;
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const MaterialApp(
                locale: Locale('en'),
                supportedLocales: S.supportedLocales,
                localizationsDelegates: S.localizationsDelegates,
                home: Scaffold(
                  body: CustomScrollView(
                    slivers: [
                      FileExplorerWidget(
                        work: Work(id: 42, title: 'Online work'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          for (
            var frame = 0;
            frame < 200 && videoTab.evaluate().isEmpty;
            frame++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          expect(videoTab, findsOneWidget);
          await tester.tap(videoTab);
          await tester.pumpAndSettle();
          await tester.tap(videoRow);
          for (
            var frame = 0;
            frame < 100 && screen.evaluate().isEmpty;
            frame++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          await tester.pump(const Duration(milliseconds: 350));
          final onlinePage = tester.widget<WorkVideoPlaybackScreen>(screen);
          expect(onlinePage.localPath, useLocal ? videoFile.path : isNull);
          expect(positions.positionFor(onlinePage.videoId), savedPosition);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      },
    );
  }

  testWidgets('online video entry resolves to a work stream', (tester) async {
    SharedPreferences.setMockInitialValues({
      'server_cookie': 'controlled-cookie',
    });
    final preferences = await SharedPreferences.getInstance();
    await StorageService.initCritical(preferences: preferences);
    final library = _GatedVideoLibrary(preferences: preferences);
    const host = 'https://server.test/kikoeru';
    const token = 'controlled-token';
    final container = ProviderContainer(
      overrides: [
        kikoeruApiServiceProvider.overrideWithValue(
          _OnlineVideoTreeApi([
            {'type': 'video', 'title': 'clip.mp4', 'hash': 'clip-hash'},
          ]),
        ),
        authProvider.overrideWith(
          (ref) => _TestAuth(const AuthState(host: host, token: token)),
        ),
        downloadServiceProvider.overrideWithValue(_EmptyDownloadRepository()),
        downloadedFileStateScannerProvider.overrideWithValue(
          DownloadedFileStateScanner(
            resolveDownloadedPath: (_, __) async => null,
            downloadRootPath: () async => '/downloads',
            fileExists: (_) async => false,
          ),
        ),
        videoLibraryProvider.overrideWith((ref) => library),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                FileExplorerWidget(work: Work(id: 42, title: 'Online work')),
              ],
            ),
          ),
        ),
      ),
    );

    final videoTab = find.byKey(const ValueKey('work-resource-videos-tab'));
    for (var frame = 0; frame < 200 && videoTab.evaluate().isEmpty; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(videoTab, findsOneWidget);
    await tester.tap(videoTab);
    await tester.pumpAndSettle();
    final videoRow = find.byKey(const ValueKey('work-video-clip.mp4'));
    expect(videoRow, findsOneWidget);
    await tester.tap(videoRow);

    final screen = find.byType(WorkVideoPlaybackScreen);
    for (var frame = 0; frame < 100 && screen.evaluate().isEmpty; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 350));
    expect(screen, findsOneWidget);
    final playbackPage = tester.widget<WorkVideoPlaybackScreen>(screen);
    expect(playbackPage.fileName, 'clip.mp4');
    expect(playbackPage.folderPath, '');
    expect(playbackPage.localPath, isNull);
    expect(playbackPage.streams, hasLength(1));
    expect(
      playbackPage.streams.single.url,
      '$host/api/media/stream/clip-hash?token=$token',
    );
    expect(playbackPage.streams.single.headers, {
      'Cookie': 'controlled-cookie',
    });
    expect(
      playbackPage.videoId,
      workVideoPlaybackId(
        sourceIdentity: workVideoSourceIdentity(workId: 42, host: host),
        workId: 42,
        fileIdentity: 'clip.mp4',
      ),
    );

    Navigator.of(tester.element(screen)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
    await tester.pumpAndSettle();
    final resourceVideo = find.text('clip.mp4');
    expect(resourceVideo, findsOneWidget);
    await tester.tap(resourceVideo);
    for (var frame = 0; frame < 100 && screen.evaluate().isEmpty; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 350));
    expect(screen, findsOneWidget);
    expect(
      tester.widget<WorkVideoPlaybackScreen>(screen).videoId,
      playbackPage.videoId,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
