import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_details_screen.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/video_download_task.dart';
import 'package:kikoeru_flutter/src/videos/video_downloads.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:kikoeru_flutter/src/videos/video_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('video playback starts paused and keeps its own volume', (
    tester,
  ) async {
    final client = _TestMissavClient(_details());
    final library = await _testLibrary(
      volume: 37,
      position: const Duration(seconds: 12),
    );
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();

    expect(session.loadStreamCount, 1);
    expect(session.lastPosition, const Duration(seconds: 12));
    expect(session.lastVolume, 37);
    expect(session.playCount, 0);
    final l10n = await S.delegate.load(const Locale('en'));
    final volumeSlider = tester.widget<Slider>(
      find.byKey(const ValueKey('video-volume-slider')),
    );
    expect(volumeSlider.value, 37);

    volumeSlider.onChanged!(62);
    volumeSlider.onChangeEnd!(62);
    await tester.pumpAndSettle();
    expect(session.lastVolume, 62);
    expect(library.volume, 62);

    await tester.tap(find.byTooltip(l10n.playbackSpeed));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5×'));
    await tester.pumpAndSettle();
    expect(session.lastRate, 1.5);

    await tester.tap(find.byTooltip(l10n.videoQuality));
    await tester.pumpAndSettle();
    await tester.tap(find.text('720p'));
    await tester.pumpAndSettle();
    expect(session.loadStreamCount, 2);
    expect(session.lastPosition, const Duration(seconds: 12));

    await tester.tap(find.byTooltip(l10n.videoPlay));
    await tester.pump();
    expect(session.playCount, 1);

    await tester.tap(find.byTooltip(l10n.videoFullscreen));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);
    expect(session.loadStreamCount, 2);
    expect(session.playCount, 1);

    await tester.tap(find.byTooltip(l10n.videoFullscreen));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);
  });

  testWidgets('fullscreen volume control updates while playback is paused', (
    tester,
  ) async {
    final client = _TestMissavClient(_details());
    final library = await _testLibrary(volume: 37);
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();
    expect(session.playCount, 0);

    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.videoFullscreen));
    await tester.pumpAndSettle();
    final volumeSlider = tester.widget<Slider>(
      find.byKey(const ValueKey('video-volume-slider')),
    );
    volumeSlider.onChanged!(68);
    volumeSlider.onChangeEnd!(68);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Slider>(find.byKey(const ValueKey('video-volume-slider')))
          .value,
      68,
    );
    expect(session.lastVolume, 68);
    expect(library.volume, 68);
    expect(session.playCount, 0);
  });

  testWidgets('fullscreen quality loading and errors remain visible paused', (
    tester,
  ) async {
    final client = _TestMissavClient(_details());
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();
    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.videoFullscreen));
    await tester.pumpAndSettle();

    final loading = Completer<void>();
    session.nextLoadCompleter = loading;
    await tester.tap(find.byTooltip(l10n.videoQuality));
    await tester.pumpAndSettle();
    await tester.tap(find.text('720p'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('video-playback-loading')),
      findsOneWidget,
    );
    loading.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-playback-loading')), findsNothing);

    session.nextLoadError = StateError('Fixture stream error');
    await tester.tap(find.byTooltip(l10n.videoQuality));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auto'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.videoPlaybackFailed), findsOneWidget);
    expect(find.byKey(const ValueKey('video-playback-loading')), findsNothing);
    expect(session.playCount, 0);
  });

  testWidgets('account change clears and reloads detail favorite state', (
    tester,
  ) async {
    final client = _TestMissavClient(_details());
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.bookmark_outline), findsOneWidget);

    client.switchAccount(isFavorite: true);
    await tester.pumpAndSettle();

    expect(client.detailsCalls, 2);
    expect(find.byIcon(Icons.bookmark), findsOneWidget);
  });

  testWidgets('actor menu sends the selected favorite state to the source', (
    tester,
  ) async {
    const actor = VideoLink(
      label: 'Fixture actor',
      url: 'https://missav.ai/cn/actress/fixture',
      kind: VideoLinkKind.actor,
    );
    final client = _TestMissavClient(
      VideoDetails(
        video: _video(),
        actors: [actor],
        streams: _details().streams,
      ),
      loggedIn: true,
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip('Fixture actor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.videoFavoriteActor));
    await tester.pumpAndSettle();

    expect(client.actorFavoriteChanges, [true]);
  });

  testWidgets('covering or backgrounding the detail pauses without resuming', (
    tester,
  ) async {
    final client = _TestMissavClient(_details());
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();
    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();

    final navigator = Navigator.of(
      tester.element(find.byType(VideoDetailsScreen)),
    );
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Cover route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(session.pauseCount, greaterThan(0));
    navigator.pop();
    await tester.pumpAndSettle();
    expect(session.playCount, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(session.pauseCount, greaterThan(1));
    expect(session.playCount, 0);
  });

  testWidgets('downloaded details skip online detail loading', (tester) async {
    final client = _TestMissavClient(
      _details(),
      initializeError: StateError('Secure storage unavailable'),
    );
    final library = await _testLibrary();
    final task = VideoDownloadTask(
      id: 'dvd-1',
      video: _video(),
      quality: 'Auto',
      isHls: true,
      status: VideoDownloadStatus.completed,
      progress: 1,
      localPath: '/offline/video/index.m3u8',
    );
    final downloads = _TestVideoDownloads(
      client: client,
      library: library,
      task: task,
    );
    final session = _FakePlaybackSession();

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        VideoDetailsScreen(
          video: _video(),
          downloadedTask: task,
          sessionFactory: () => session,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(client.detailsCalls, 0);
    expect(client.initializeCalls, 0);
    expect(session.loadFileCount, 1);
    expect(session.localPath, task.localPath);
    expect(session.loadStreamCount, 0);
  });

  testWidgets('detail layout fits 360px and 1280px windows at 1.3 text scale', (
    tester,
  ) async {
    final client = _TestMissavClient(
      VideoDetails(
        video: _video(),
        description: 'A fixture description that exercises wrapping.',
        metadata: const {'Studio': 'A studio with a longer name'},
        actors: const [
          VideoLink(
            label: 'A performer with a long name',
            url: 'https://missav.ai/cn/actress/fixture',
            kind: VideoLinkKind.actor,
          ),
        ],
        tags: const [
          VideoLink(
            label: 'A category with a longer name',
            url: 'https://missav.ai/cn/genre/fixture',
            kind: VideoLinkKind.category,
          ),
        ],
        related: [
          for (var index = 0; index < 4; index++)
            VideoItem(
              id: 'related-$index',
              title: 'Related fixture video $index',
              pageUrl: 'https://missav.ai/cn/related-$index',
            ),
        ],
        streams: const [
          VideoStream(label: 'Auto', url: 'https://cdn.example/video.m3u8'),
        ],
      ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();

    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
        textScale: 1.3,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1280, 900);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });

  testWidgets('playlist dialog uses source membership and updates remotely', (
    tester,
  ) async {
    final client = _TestMissavClient(_details(), loggedIn: true)
      ..playlists = [
        const VideoLink(
          label: 'Fixture playlist',
          url: 'https://missav.ai/cn/playlists',
          kind: VideoLinkKind.playlist,
          sourceKey: 'playlist-key',
          isAdded: false,
        ),
      ];
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final session = _FakePlaybackSession();

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        VideoDetailsScreen(video: _video(), sessionFactory: () => session),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.videoAddToPlaylist));
    await tester.pumpAndSettle();

    expect(client.playlistsCalls, 1);
    expect(find.text('Fixture playlist'), findsOneWidget);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(client.addedPlaylists, ['playlist-key']);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(
  _TestMissavClient client,
  VideoLibrary library,
  VideoDownloads downloads,
  Widget home, {
  double textScale = 1,
}) => ProviderScope(
  overrides: [
    videoClientProvider.overrideWith((ref) => client),
    videoLibraryProvider.overrideWith((ref) => library),
    videoDownloadsProvider.overrideWith((ref) => downloads),
    currentTrackProvider.overrideWith((ref) => Stream.value(null)),
  ],
  child: MaterialApp(
    locale: const Locale('en'),
    supportedLocales: S.supportedLocales,
    localizationsDelegates: S.localizationsDelegates,
    theme: ThemeData(useMaterial3: true),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: home,
  ),
);

Future<VideoLibrary> _testLibrary({double? volume, Duration? position}) async {
  SharedPreferences.setMockInitialValues({
    if (volume != null) 'video_volume_v1': volume,
  });
  final library = VideoLibrary(
    preferences: await SharedPreferences.getInstance(),
  );
  await library.initialize();
  if (position != null) await library.savePosition('dvd-1', position);
  return library;
}

VideoItem _video() => const VideoItem(
  id: 'dvd-1',
  title: 'Fixture video',
  pageUrl: 'https://missav.ai/cn/dvd-1',
);

VideoDetails _details({bool isFavorite = false}) => VideoDetails(
  video: _video(),
  streams: const [
    VideoStream(label: 'Auto', url: 'https://cdn.example/video.m3u8'),
    VideoStream(label: '720p', url: 'https://cdn.example/video-720.m3u8'),
  ],
  sourceId: 'source-id',
  isFavorite: isFavorite,
);

class _TestMissavClient extends MissavClient {
  _TestMissavClient(
    this.detailsResult, {
    this.loggedIn = false,
    this.initializeError,
  });

  VideoDetails detailsResult;
  bool loggedIn;
  final Object? initializeError;
  String? _accountName;
  final List<bool> actorFavoriteChanges = [];
  int initializeCalls = 0;
  int detailsCalls = 0;
  int playlistsCalls = 0;
  List<VideoLink> playlists = [];
  final List<String> addedPlaylists = [];

  @override
  String get homeUrl => 'https://missav.ai/cn';

  @override
  bool get isLoggedIn => loggedIn;

  @override
  String? get accountName => _accountName;

  void switchAccount({required bool isFavorite}) {
    loggedIn = true;
    _accountName = 'Account B';
    detailsResult = _details(isFavorite: isFavorite);
    notifyListeners();
  }

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (initializeError != null) throw initializeError!;
  }

  @override
  Future<VideoDetails> details(VideoItem item) async {
    detailsCalls++;
    return detailsResult;
  }

  @override
  Future<List<VideoLink>> playlistsFor(VideoItem item) async {
    playlistsCalls++;
    return playlists;
  }

  @override
  Future<void> addToPlaylist(VideoLink playlist, VideoItem item) async {
    addedPlaylists.add(playlist.sourceKey!);
  }

  @override
  Future<void> setActorFavorite(VideoLink actor, bool favorite) async {
    actorFavoriteChanges.add(favorite);
  }
}

class _TestVideoDownloads extends VideoDownloads {
  _TestVideoDownloads({
    required super.client,
    required super.library,
    this.task,
  });

  final VideoDownloadTask? task;

  @override
  Future<void> initialize() async {}

  @override
  VideoDownloadTask? forVideo(String videoId) =>
      task?.id == videoId ? task : null;

  @override
  List<VideoDownloadTask> get tasks => task == null ? const [] : [task!];
}

class _FakePlaybackSession implements VideoPlaybackSession {
  final ValueNotifier<VideoPlaybackSnapshot> _snapshot = ValueNotifier(
    const VideoPlaybackSnapshot(),
  );
  int loadStreamCount = 0;
  int loadFileCount = 0;
  int playCount = 0;
  int pauseCount = 0;
  int disposeCount = 0;
  Duration lastPosition = Duration.zero;
  double lastVolume = 0;
  double lastRate = 1;
  String? localPath;
  Completer<void>? nextLoadCompleter;
  Object? nextLoadError;

  @override
  ValueListenable<VideoPlaybackSnapshot> get snapshot => _snapshot;

  @override
  Widget buildSurface({required double aspectRatio}) => const ColoredBox(
    key: ValueKey('fake-video-surface'),
    color: Colors.black,
  );

  @override
  Future<void> loadStream(
    VideoStream stream, {
    required Duration position,
    required double volume,
  }) async {
    loadStreamCount++;
    lastPosition = position;
    lastVolume = volume;
    final loadCompleter = nextLoadCompleter;
    nextLoadCompleter = null;
    if (loadCompleter != null) await loadCompleter.future;
    final error = nextLoadError;
    nextLoadError = null;
    if (error != null) throw error;
    _snapshot.value = _snapshot.value.copyWith(
      position: position,
      duration: const Duration(minutes: 3),
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
    localPath = path;
    lastPosition = position;
    lastVolume = volume;
    _snapshot.value = _snapshot.value.copyWith(
      position: position,
      duration: const Duration(minutes: 3),
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
    lastPosition = position;
    _snapshot.value = _snapshot.value.copyWith(position: position);
  }

  @override
  Future<void> setRate(double rate) async {
    lastRate = rate;
    _snapshot.value = _snapshot.value.copyWith(rate: rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    lastVolume = volume;
  }

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
