import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/videos/jable_client.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_collection_view.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_details_screen.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/video_downloads.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:kikoeru_flutter/src/videos/video_playback_settings.dart';
import 'package:kikoeru_flutter/src/videos/video_player_platform.dart';
import 'package:kikoeru_flutter/src/videos/video_providers.dart';
import 'package:kikoeru_flutter/src/widgets/app_navigation_scope.dart';

typedef _MissavAccessVerifier =
    Future<bool> Function(
      BuildContext context,
      MissavClient client, {
      required String sourceUrl,
      bool requireLogin,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'MissAV shows a skeleton, retries recommendations only, and keeps playback',
    (tester) async {
      final firstResponse = Completer<List<VideoItem>>();
      final retryResponse = Completer<List<VideoItem>>();
      final video = _video('first');
      final related = _video('related', title: 'Related source video');
      final client = _FakeMissavClient({
        video.id: _details(video, related: [_video('stale-html')]),
      });
      var recommendationCalls = 0;
      client.relatedLoader = (_) {
        recommendationCalls++;
        return recommendationCalls == 1
            ? firstResponse.future
            : retryResponse.future;
      };
      final sessions = await _pumpDetails(tester, client: client, video: video);
      final s = await S.delegate.load(const Locale('en'));

      expect(recommendationCalls, 1);
      expect(find.text(s.videoRelated), findsOneWidget);
      expect(find.byType(MasonryGridView), findsOneWidget);
      expect(find.byType(VideoCard), findsNothing);
      expect(sessions, hasLength(1));
      expect(sessions.single.loadStreamCount, 1);

      firstResponse.completeError(const MissavException('Batch failed.'));
      await tester.pumpAndSettle();
      expect(find.text(s.loadFailedRetry), findsOneWidget);
      expect(find.byType(MasonryGridView), findsNothing);

      await tester.ensureVisible(find.text(s.loadFailedRetry));
      await tester.tap(find.text(s.loadFailedRetry));
      await tester.pumpAndSettle();
      expect(recommendationCalls, 2);
      expect(client.detailsCalls, 1);
      expect(sessions, hasLength(1));
      expect(sessions.single.loadStreamCount, 1);
      expect(find.byType(MasonryGridView), findsOneWidget);

      retryResponse.complete([related]);
      await tester.pumpAndSettle();
      expect(find.text(related.title), findsOneWidget);
      expect(find.text('stale-html'), findsNothing);
      expect(client.detailsCalls, 1);
      expect(sessions, hasLength(1));
      expect(sessions.single.loadStreamCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('MissAV hides the recommendation section for an empty result', (
    tester,
  ) async {
    final video = _video('empty-result');
    final client = _FakeMissavClient({
      video.id: _details(video, related: [_video('stale-html')]),
    })..relatedLoader = (_) async => [];
    await _pumpDetails(tester, client: client, video: video);
    final s = await S.delegate.load(const Locale('en'));

    expect(find.text(s.videoRelated), findsNothing);
    expect(find.text('stale-html'), findsNothing);
    expect(find.byType(VideoCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Jable keeps the final related cards and adapts across widths', (
    tester,
  ) async {
    final video = _video('jable-first', sourceKey: 'jable');
    final firstRelated = _video(
      'jable-related-first',
      sourceKey: 'jable',
      title: 'Related Jable one',
    );
    final secondRelated = _video(
      'jable-related-second',
      sourceKey: 'jable',
      title: 'Related Jable two',
    );
    final client = _FakeMissavClient({video.id: _details(video)});
    final enrichedDetails = Completer<VideoDetails>();
    final jable =
        _FakeJableClient({
            video.id: _details(video, related: [firstRelated, secondRelated]),
            firstRelated.id: _details(firstRelated),
            secondRelated.id: _details(secondRelated),
          })
          ..readyDetails = _details(video)
          ..detailsCompleter = enrichedDetails;
    final sessions = await _pumpDetails(
      tester,
      client: client,
      video: video,
      jableClient: jable,
    );

    expect(find.byType(VideoCard), findsNothing);
    expect(sessions.single.loadStreamCount, 1);
    enrichedDetails.complete(
      _details(video, related: [firstRelated, secondRelated]),
    );
    await tester.pumpAndSettle();
    jable.readyDetails = null;
    jable.detailsCompleter = null;
    expect(find.byType(VideoCard), findsNWidgets(2));
    expect(find.text(firstRelated.title), findsOneWidget);
    expect(find.text(secondRelated.title), findsOneWidget);
    expect(client.recommendationCalls, 0);
    expect(sessions.single.loadStreamCount, 1);

    tester.view.physicalSize = const Size(1180, 1600);
    await tester.pumpAndSettle();
    expect(find.byType(VideoCard), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text(firstRelated.title));
    await tester.tap(find.text(firstRelated.title));
    await tester.pumpAndSettle();
    expect(jable.requestedVideos.last.id, firstRelated.id);
  });

  testWidgets(
    'MissAV auto-advances when recommendations arrive after completion',
    (tester) async {
      final first = _video('autoplay-first');
      final second = _video('autoplay-second', title: 'Autoplay second');
      final recommendations = Completer<List<VideoItem>>();
      final client =
          _FakeMissavClient({
              first.id: _details(first),
              second.id: _details(second),
            })
            ..relatedLoader = (video) => video.id == first.id
                ? recommendations.future
                : Future.value(const []);
      final sessions = await _pumpDetails(
        tester,
        client: client,
        video: first,
        preferences: {
          'video_player_v1_repeat_mode': VideoPlayerRepeatMode.related.index,
        },
      );

      expect(sessions, hasLength(1));
      expect(client.recommendationCalls, 1);

      sessions.single.complete();
      await tester.pumpAndSettle();
      expect(client.detailsCalls, 1);

      recommendations.complete([second]);
      await tester.pumpAndSettle();

      expect(client.detailsCalls, 2);
      expect(find.text(second.title), findsWidgets);
      expect(sessions, hasLength(2));
      expect(sessions.last.playCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'MissAV keeps the completed video when recommendations arrive in another tab',
    (tester) async {
      final first = _video('completed-first');
      final second = _video('late-second');
      final recommendations = Completer<List<VideoItem>>();
      final navigation = AppNavigationController()..selectTab(appVideoTabIndex);
      addTearDown(navigation.dispose);
      final client = _FakeMissavClient({
        first.id: _details(first),
        second.id: _details(second),
      })..relatedLoader = (_) => recommendations.future;
      final sessions = await _pumpDetails(
        tester,
        client: client,
        video: first,
        navigation: navigation,
        preferences: {
          'video_player_v1_repeat_mode': VideoPlayerRepeatMode.related.index,
        },
      );

      sessions.single.complete();
      await tester.pumpAndSettle();
      navigation.selectTab(appAudioTabIndex);
      await tester.pumpAndSettle();
      recommendations.complete([second]);
      await tester.pumpAndSettle();

      expect(client.detailsCalls, 1);
      expect(sessions, hasLength(1));
      navigation.selectTab(appVideoTabIndex);
      await tester.pumpAndSettle();
      expect(client.detailsCalls, 1);
      expect(find.text(first.title), findsWidgets);
      expect(sessions.single.playCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ignores recommendations from the previous video', (
    tester,
  ) async {
    final first = _video('old-video');
    final second = _video('new-video');
    final stale = _video('old-recommendation');
    final current = _video('new-recommendation');
    final oldRequest = Completer<List<VideoItem>>();
    final newRequest = Completer<List<VideoItem>>();
    final selected = ValueNotifier(first);
    addTearDown(selected.dispose);
    final client =
        _FakeMissavClient({
            first.id: _details(first),
            second.id: _details(second),
          })
          ..relatedLoader = (video) =>
              video.id == first.id ? oldRequest.future : newRequest.future;
    await _pumpDetails(
      tester,
      client: client,
      video: first,
      videoListenable: selected,
    );

    selected.value = second;
    await tester.pumpAndSettle();
    newRequest.complete([current]);
    await tester.pumpAndSettle();
    oldRequest.complete([stale]);
    await tester.pumpAndSettle();

    expect(find.text(current.title), findsOneWidget);
    expect(find.text(stale.title), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reloads recommendations after the MissAV session changes', (
    tester,
  ) async {
    final video = _video('session-change');
    final stale = _video('stale-session-recommendation');
    final current = _video('current-session-recommendation');
    final firstRequest = Completer<List<VideoItem>>();
    final secondRequest = Completer<List<VideoItem>>();
    final client = _FakeMissavClient({video.id: _details(video)});
    var recommendationCalls = 0;
    client.relatedLoader = (_) {
      recommendationCalls++;
      return recommendationCalls == 1
          ? firstRequest.future
          : secondRequest.future;
    };
    await _pumpDetails(tester, client: client, video: video);

    expect(client.detailsCalls, 1);
    expect(recommendationCalls, 1);
    client.changeSession();
    await tester.pumpAndSettle();

    expect(client.detailsCalls, 2);
    expect(recommendationCalls, 2);
    firstRequest.complete([stale]);
    await tester.pumpAndSettle();
    expect(find.text(stale.title), findsNothing);

    secondRequest.complete([current]);
    await tester.pumpAndSettle();
    expect(find.text(current.title), findsOneWidget);
    expect(find.text(stale.title), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('verification session changes discard the old recommendation', (
    tester,
  ) async {
    final video = _video('verification-session');
    final stale = _video('stale-verification-recommendation');
    final current = _video('verified-recommendation');
    final firstRequest = Completer<List<VideoItem>>();
    final secondRequest = Completer<List<VideoItem>>();
    final verification = Completer<void>();
    final client = _FakeMissavClient({video.id: _details(video)});
    var recommendationCalls = 0;
    var verificationCalls = 0;
    client.relatedLoader = (_) {
      recommendationCalls++;
      return recommendationCalls == 1
          ? firstRequest.future
          : secondRequest.future;
    };
    final sessions = await _pumpDetails(
      tester,
      client: client,
      video: video,
      missavAccessVerifier:
          (_, _, {required sourceUrl, requireLogin = false}) async {
            expect(sourceUrl, video.pageUrl);
            expect(requireLogin, isFalse);
            verificationCalls++;
            client.changeSession();
            await verification.future;
            return true;
          },
    );
    final s = await S.delegate.load(const Locale('en'));

    expect(recommendationCalls, 1);
    sessions.single.emitError(
      'The media server requires browser verification.',
    );
    await tester.pump();
    await tester.tap(find.text(s.videoVerifyAccess));
    await tester.pump();

    expect(verificationCalls, 1);
    firstRequest.complete([stale]);
    await tester.pumpAndSettle();
    expect(find.text(stale.title), findsNothing);

    verification.complete();
    await tester.pumpAndSettle();
    expect(client.detailsCalls, 2);
    expect(recommendationCalls, 2);

    secondRequest.complete([current]);
    await tester.pumpAndSettle();
    expect(find.text(current.title), findsOneWidget);
    expect(find.text(stale.title), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final recommendationsFinishFirst in [true, false]) {
    testWidgets(
      'recommendations ${recommendationsFinishFirst ? 'precede' : 'follow'} detail supplementation without replacing the player',
      (tester) async {
        final video = _video('race-video');
        final related = _video('race-related', title: 'Race recommendation');
        final preview = _details(video, related: [_video('stale-preview')]);
        final supplemented = _details(
          video,
          related: [_video('stale-supplemented')],
        );
        final recommendations = Completer<List<VideoItem>>();
        final details = Completer<VideoDetails>();
        final client = _FakeMissavClient({video.id: supplemented})
          ..readyDetails = preview
          ..detailsCompleter = details
          ..relatedLoader = (_) => recommendations.future;
        final sessions = await _pumpDetails(
          tester,
          client: client,
          video: video,
        );

        expect(sessions, hasLength(1));
        expect(sessions.single.loadStreamCount, 1);
        if (recommendationsFinishFirst) {
          recommendations.complete([related]);
          await tester.pumpAndSettle();
          expect(find.text(related.title), findsOneWidget);
          details.complete(supplemented);
          await tester.pumpAndSettle();
        } else {
          details.complete(supplemented);
          await tester.pumpAndSettle();
          expect(find.text(related.title), findsNothing);
          recommendations.complete([related]);
          await tester.pumpAndSettle();
        }

        expect(find.text(related.title), findsOneWidget);
        expect(find.text('stale-preview'), findsNothing);
        expect(find.text('stale-supplemented'), findsNothing);
        expect(client.recommendationCalls, 1);
        expect(sessions, hasLength(1));
        expect(sessions.single.loadStreamCount, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<List<_FakePlaybackSession>> _pumpDetails(
  WidgetTester tester, {
  required _FakeMissavClient client,
  required VideoItem video,
  _FakeJableClient? jableClient,
  _MissavAccessVerifier? missavAccessVerifier,
  AppNavigationController? navigation,
  ValueListenable<VideoItem>? videoListenable,
  Map<String, Object> preferences = const {},
}) async {
  SharedPreferences.setMockInitialValues(preferences);
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  final library = VideoLibrary(
    preferences: await SharedPreferences.getInstance(),
  );
  final downloads = _FakeVideoDownloads(client: client, library: library);
  final sessions = <_FakePlaybackSession>[];
  Widget details(VideoItem item) => VideoDetailsScreen(
    video: item,
    sessionFactory: () {
      final session = _FakePlaybackSession();
      sessions.add(session);
      return session;
    },
    platformFactory: () => _FakeVideoPlayerPlatform(),
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        videoClientProvider.overrideWith((ref) => client),
        if (missavAccessVerifier != null)
          missavAccessVerifierProvider.overrideWithValue(missavAccessVerifier),
        if (jableClient != null)
          jableVideoClientProvider.overrideWith((ref) {
            ref.onDispose(jableClient.dispose);
            return jableClient;
          }),
        videoLibraryProvider.overrideWith((ref) => library),
        videoDownloadsProvider.overrideWith((ref) => downloads),
        currentTrackProvider.overrideWith((ref) => Stream.value(null)),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        navigatorObservers: [if (navigation != null) navigation],
        builder: navigation == null
            ? null
            : (context, child) => AppNavigationScope(
                controller: navigation,
                mediaQuery: MediaQuery.of(context),
                navigationMotion: const AlwaysStoppedAnimation<double>(0),
                child: child!,
              ),
        home: videoListenable == null
            ? details(video)
            : ValueListenableBuilder<VideoItem>(
                valueListenable: videoListenable,
                builder: (_, item, __) => details(item),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return sessions;
}

const _streams = [
  VideoStream(label: 'Auto', url: 'https://cdn.example/video.m3u8'),
];

VideoItem _video(String id, {String? title, String sourceKey = 'missav'}) =>
    VideoItem(
      id: id,
      title: title ?? id,
      sourceKey: sourceKey,
      pageUrl: sourceKey == 'jable'
          ? 'https://jable.tv/videos/$id'
          : 'https://missav.ai/cn/$id',
    );

VideoDetails _details(VideoItem video, {List<VideoItem> related = const []}) =>
    VideoDetails(video: video, streams: _streams, related: related);

class _FakeMissavClient extends MissavClient {
  _FakeMissavClient(this.detailsById);

  final Map<String, VideoDetails> detailsById;
  final List<VideoItem> requestedRecommendations = [];
  VideoDetails? readyDetails;
  Completer<VideoDetails>? detailsCompleter;
  Future<List<VideoItem>> Function(VideoItem video)? relatedLoader;
  int _sessionGeneration = 0;
  int detailsCalls = 0;
  int recommendationCalls = 0;

  @override
  int get sessionGeneration => _sessionGeneration;

  void changeSession() {
    _sessionGeneration++;
    notifyListeners();
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<VideoDetails> details(
    VideoItem item, {
    FutureOr<void> Function(VideoDetails)? onReady,
    bool includeAccountState = true,
  }) async {
    detailsCalls++;
    final details = detailsById[item.id] ?? _details(item);
    final ready = detailsCalls == 1 ? readyDetails ?? details : details;
    await onReady?.call(ready);
    return detailsCompleter?.future ?? details;
  }

  @override
  Future<List<VideoItem>> loadRelatedRecommendations(VideoItem video) {
    recommendationCalls++;
    requestedRecommendations.add(video);
    return relatedLoader?.call(video) ?? Future.value(const []);
  }
}

class _FakeJableClient extends JableClient {
  _FakeJableClient(this.detailsById);

  final Map<String, VideoDetails> detailsById;
  final List<VideoItem> requestedVideos = [];
  VideoDetails? readyDetails;
  Completer<VideoDetails>? detailsCompleter;

  @override
  Future<void> initialize() async {}

  @override
  Future<VideoDetails> details(
    VideoItem item, {
    FutureOr<void> Function(VideoDetails)? onReady,
    bool includeAccountState = true,
  }) async {
    requestedVideos.add(item);
    final details = detailsById[item.id] ?? _details(item);
    await onReady?.call(readyDetails ?? details);
    return detailsCompleter?.future ?? details;
  }
}

class _FakeVideoDownloads extends VideoDownloads {
  _FakeVideoDownloads({required super.client, required super.library});

  @override
  Future<void> initialize() async {}
}

class _FakePlaybackSession implements VideoPlaybackSession {
  final ValueNotifier<VideoPlaybackSnapshot> _snapshot = ValueNotifier(
    const VideoPlaybackSnapshot(),
  );
  int loadStreamCount = 0;
  int playCount = 0;

  void emitError(String error) {
    _snapshot.value = _snapshot.value.copyWith(error: error, buffering: true);
  }

  void complete() {
    _snapshot.value = _snapshot.value.copyWith(completed: true, playing: false);
  }

  @override
  ValueListenable<VideoPlaybackSnapshot> get snapshot => _snapshot;

  @override
  Widget buildSurface({required double aspectRatio}) => AspectRatio(
    aspectRatio: aspectRatio,
    child: const ColoredBox(color: Colors.black),
  );

  @override
  Future<void> loadStream(
    VideoStream stream, {
    required Duration position,
    required double volume,
  }) async {
    loadStreamCount++;
    _snapshot.value = _snapshot.value.copyWith(
      position: position,
      duration: const Duration(minutes: 3),
    );
  }

  @override
  Future<void> loadFile(
    String path, {
    required Duration position,
    required double volume,
  }) async {}

  @override
  Future<void> play() async {
    playCount++;
    _snapshot.value = _snapshot.value.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> selectAudioTrack(String id) async {}

  @override
  Future<void> selectSubtitleTrack(String id) async {}

  @override
  Future<void> dispose() async => _snapshot.dispose();
}

class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  _FakeVideoPlayerPlatform() : super(platform: TargetPlatform.windows);

  final ValueNotifier<bool> _pictureInPicture = ValueNotifier(false);

  @override
  ValueListenable<bool> get pictureInPicture => _pictureInPicture;

  @override
  bool get supportsBrightness => false;

  @override
  bool get supportsPictureInPicture => false;

  @override
  bool get supportsSystemBrightness => false;

  @override
  bool get supportsBatteryStatus => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isAlwaysOnTop() async => false;

  @override
  Future<double> getBrightness() async => 0.5;

  @override
  Future<void> setKeepScreenOn(bool enabled) async {}

  @override
  Future<void> setBackgroundPlayback(bool enabled) async {}

  @override
  Future<void> setAutoPictureInPicture(
    bool enabled, {
    double aspectRatio = 16 / 9,
  }) async {}

  @override
  Future<void> dispose() async => _pictureInPicture.dispose();
}
