import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/player_work_details_provider.dart';
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';

void main() {
  test('fifty switches over one file-tree id classify only once', () async {
    final classifier = _CountingClassifier();
    final repository = PlayerWorkDetailsRepository(
      classifier: classifier,
      cacheCapacity: 8,
    );
    final fileTree = <dynamic>[
      {
        'type': 'folder',
        'title': '简中_有SE',
        'children': [
          {'type': 'audio', 'title': 'track.wav', 'hash': 'audio'},
          {'type': 'text', 'title': 'track_简中.lrc', 'hash': 'lyric'},
        ],
      },
    ];

    for (var index = 0; index < 50; index++) {
      await repository.load(
        track: AudioTrack(
          id: 'track-$index',
          title: 'Track $index',
          url: 'https://example.invalid/$index',
          workId: 100,
        ),
        fileTree: fileTree,
        canUseRemoteMetadata: false,
        loadRemoteWork: (_) async => throw StateError('must stay offline'),
      );
    }

    expect(classifier.scans, 1);
    expect(repository.debugClassificationCount, 1);
    expect(repository.debugCacheSize, 1);
  });

  test('details scan cache remains bounded', () async {
    final repository = PlayerWorkDetailsRepository(cacheCapacity: 4);
    for (var index = 0; index < 12; index++) {
      await repository.load(
        track: AudioTrack(
          id: 'track-$index',
          title: 'Track $index',
          url: 'local-$index',
          workId: index + 1,
        ),
        fileTree: [
          {'type': 'audio', 'title': '$index.flac', 'hash': '$index'},
        ],
        canUseRemoteMetadata: false,
        loadRemoteWork: (_) async => const <String, dynamic>{},
      );
    }
    expect(repository.debugCacheSize, 4);
  });

  test('logged-out online details never request a remote file tree', () {
    const onlineTrack = AudioTrack(
      id: 'online',
      title: 'Online track',
      url: 'https://example.invalid/audio.flac',
      workId: 42,
    );
    const offlineTrack = AudioTrack(
      id: 'offline',
      title: 'Offline track',
      url: 'file:///audio.flac',
      workId: 42,
      subtitleWorkDirPath: 'C:/Library/RJ42',
    );

    expect(
      canLoadPlayerWorkFileTree(
        track: onlineTrack,
        isLoggedIn: false,
        host: 'https://example.invalid',
      ),
      isFalse,
    );
    expect(
      canLoadPlayerWorkFileTree(
        track: onlineTrack,
        isLoggedIn: true,
        host: 'https://example.invalid',
      ),
      isTrue,
    );
    expect(
      canLoadPlayerWorkFileTree(
        track: offlineTrack,
        isLoggedIn: false,
        host: null,
      ),
      isTrue,
    );
  });

  test(
    'player glass is centralized and position updates stay outside the page',
    () {
      final screen = File(
        'lib/src/screens/audio_player_screen.dart',
      ).readAsStringSync();
      final playerWidgets = Directory('lib/src/widgets/player')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .map((file) => file.readAsStringSync())
          .join('\n');
      final detailsPanel = File(
        'lib/src/widgets/player/player_audio_details_panel.dart',
      ).readAsStringSync();
      final glassSurface = File(
        'lib/src/widgets/player/player_glass_surface.dart',
      ).readAsStringSync();
      final lyricDisplay = File(
        'lib/src/widgets/player/lyric_display_widget.dart',
      ).readAsStringSync();
      final lyricSurface = File(
        'lib/src/widgets/player/player_lyrics_surface.dart',
      ).readAsStringSync();
      final playerRoute = File(
        'lib/src/widgets/player/player_route.dart',
      ).readAsStringSync();
      final playerCover = File(
        'lib/src/widgets/player/player_cover_widget.dart',
      ).readAsStringSync();
      final miniPlayer = File(
        'lib/src/widgets/mini_player.dart',
      ).readAsStringSync();
      final infoPanel = File(
        'lib/src/widgets/player/player_info_panel.dart',
      ).readAsStringSync();

      expect(screen, isNot(contains('BackdropFilter')));
      expect(glassSurface, contains('BackdropFilter.grouped'));
      expect(glassSurface, contains('BackdropGroup'));
      expect(glassSurface, contains('this.sigma = 6'));
      expect(glassSurface, contains('class PlayerTransientGlassSurface'));
      expect(glassSurface, contains('static const double blurSigma = 10'));
      expect(glassSurface, contains('class PlayerGlassMaterial'));
      expect(infoPanel, contains('PlayerGlassMaterial('));
      expect(glassSurface, contains('RepaintBoundary'));
      expect(glassSurface, contains('borderRadius: borderRadius'));
      expect(
        playerWidgets.replaceFirst(glassSurface, ''),
        isNot(contains('ImageFilter.blur')),
      );
      expect(screen, isNot(contains('ref.watch(positionProvider)')));
      expect(screen, contains('RepaintBoundary'));
      expect(detailsPanel, contains('SliverList.builder'));
      expect(screen, contains('ref.listen(playerWorkDetailsProvider'));
      expect(detailsPanel, contains('enabled: widget.isActive'));
      expect(
        detailsPanel,
        isNot(contains('inactive-player-audio-details-panel')),
      );
      expect(detailsPanel, isNot(contains('for (final variant in variants)')));
      expect(lyricDisplay, isNot(contains('ensureVisible')));
      expect(lyricDisplay, contains('_centerInsideVisibleViewport'));
      expect(lyricDisplay, contains('class _LyricLayoutIndex'));
      expect(lyricDisplay, contains('itemExtentBuilder:'));
      expect(lyricDisplay, contains('RenderParagraph'));
      expect(lyricDisplay, contains('centerOnMatch('));
      expect(lyricDisplay, isNot(contains('_paddingCompensationGeneration')));
      expect(lyricDisplay, contains('ClampingScrollPhysics'));
      expect(lyricDisplay, contains('Timer(const Duration(seconds: 2)'));
      expect(
        lyricDisplay,
        contains("ValueKey('compact-lyric-line-\$lyricIndex')"),
      );
      expect(
        lyricDisplay,
        contains("ValueKey('compact-lyric-edge-fade-mask')"),
      );
      expect(lyricDisplay, contains('playerLyricEdgeFadeGradient('));
      expect(lyricSurface, contains('playerLyricEdgeFadeGradient('));
      expect(lyricDisplay, contains('widget.onSeekRequested('));
      expect(screen, contains("ValueKey('compact-main-lyric-scroll-surface')"));
      expect(
        screen,
        isNot(contains("ValueKey('compact-main-lyric-queue-surface')")),
      );
      expect(lyricSurface, isNot(contains('AnimatedPositioned')));
      expect(lyricSurface, contains('Transform.translate'));
      expect(lyricSurface, contains('Alignment.bottomCenter'));
      expect(lyricSurface, contains('reserveSearchCenteringSpace: true'));
      expect(lyricSurface, contains('child: lyricList'));
      expect(screen, contains('AutomaticKeepAliveClientMixin'));
      expect(screen, contains('_semanticPageRevision'));
      final semanticPageHandlers = screen.substring(
        screen.indexOf('void _onCompactPageChanged'),
        screen.indexOf('void _animateSemanticPage'),
      );
      expect(semanticPageHandlers, contains('_commitSemanticPage'));
      expect(semanticPageHandlers, isNot(contains('setState(')));
      expect(screen, contains('PlayerInteractiveDismissRoute'));
      expect(screen, contains('_currentPlayerDismissVisualMode'));
      expect(playerRoute, contains('beginVerticalDismissGesture'));
      expect(
        playerRoute,
        contains("ValueKey('player-route-vertical-translation')"),
      );
      expect(playerRoute, isNot(contains('heightFactor:')));
      expect(playerRoute, contains('mode == PlayerDismissVisualMode.main'));
      expect(
        playerRoute,
        contains(
          'Duration playerRouteTransitionDuration = Duration(milliseconds: 500)',
        ),
      );
      expect(playerCover, contains('transitionOnUserGestures: true'));
      expect(playerCover, contains('createPlayerArtworkRectTween'));
      expect(playerCover, contains('playerArtworkAttachmentStart = 0.20'));
      expect(playerCover, contains('playerArtworkAttachmentEnd = 0.85'));
      expect(screen, isNot(contains('PlayerArtworkFlightTarget.queue')));
      expect(miniPlayer, contains('PlayerArtworkHero('));
      expect(miniPlayer, contains('PlayerCompactArtwork('));
      expect(miniPlayer, contains('createPlayerArtworkRectTween'));
      expect(miniPlayer, contains("'mini-player-queue-button'"));
      expect(miniPlayer, contains('class _MiniPlayerTrackSwitcher'));
      expect(miniPlayer, contains('AnimatedSwitcher'));
      expect(playerCover, contains('useOldImageOnUrlChange: true'));
      expect(
        playerCover,
        contains('fadeOutDuration: const Duration(milliseconds: 220)'),
      );
      expect(miniPlayer, isNot(contains('Icons.skip_previous')));
      expect(miniPlayer, isNot(contains('Icons.skip_next')));
      expect(miniPlayer, contains('class _InteractivePlayerOpenSession'));
      expect(miniPlayer, contains('configuration.createRoute()'));
      expect(miniPlayer, contains('configuration.createRoute(handoff: true)'));
      expect(miniPlayer, contains('Navigator('));
      expect(RegExp(r'OverlayEntry\(').allMatches(miniPlayer), hasLength(1));
      expect(miniPlayer, isNot(contains('_previewController')));
      expect(miniPlayer, isNot(contains('mini-player-route-preview-slide')));
      expect(miniPlayer, contains('openPlayer'));
      expect(miniPlayer, contains('openQueue'));
      expect(screen, contains('_directQueueEntry'));
      expect(screen, contains('PlayerInitialSurface.queue'));
    },
  );

  test('mini player prepares artwork palette before opening the route', () {
    final miniPlayer = File(
      'lib/src/widgets/mini_player.dart',
    ).readAsStringSync();

    expect(miniPlayer, contains('final preparedPalette = ref.watch'));
    expect(miniPlayer, contains('preparedPalette.valueOrNull ??'));
    expect(miniPlayer, contains('playerVisualPaletteProvider('));
    expect(miniPlayer, contains('AudioPlayerOpenConfiguration('));
    expect(miniPlayer, isNot(contains('await ref.read(')));
    expect(
      miniPlayer.indexOf('final preparedPalette = ref.watch'),
      lessThan(miniPlayer.indexOf('return _MiniPlayerUpwardLauncher(')),
    );
  });

  test('artwork flights and transient notices stay centralized', () {
    final appSources = Directory('lib/src')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');
    final noticeSource = File(
      'lib/src/utils/snackbar_util.dart',
    ).readAsStringSync();
    final playerCover = File(
      'lib/src/widgets/player/player_cover_widget.dart',
    ).readAsStringSync();
    final workCover = File(
      'lib/src/widgets/work_detail/work_cover_frame.dart',
    ).readAsStringSync();

    expect(RegExp(r'\.showSnackBar\(').allMatches(appSources), hasLength(1));
    expect(noticeSource, contains('SnackBarBehavior.floating'));
    expect(noticeSource, contains('(width - 420) / 2'));
    expect(noticeSource, contains('(height * 0.18).clamp(88.0, 144.0)'));
    expect(playerCover, contains('enum PlayerArtworkFlightTarget'));
    expect(playerCover, contains('class PlayerCompactArtwork'));
    expect(playerCover, contains('Tween<double>('));
    expect(workCover, contains('class WorkCoverHeroFrame'));
    expect(workCover, contains('Tween<double>('));
  });
}

class _CountingClassifier extends PlayerAudioVariantClassifier {
  int scans = 0;

  @override
  List<PlayerAudioVariant> scan(
    List<dynamic> fileTree, {
    String workTitle = '',
  }) {
    scans++;
    return super.scan(fileTree, workTitle: workTitle);
  }
}
