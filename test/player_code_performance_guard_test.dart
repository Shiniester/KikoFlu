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

      expect(screen, isNot(contains('BackdropFilter')));
      expect(glassSurface, contains('BackdropFilter.grouped'));
      expect(glassSurface, contains('BackdropGroup'));
      expect(glassSurface, contains('this.sigma = 6'));
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
      expect(lyricDisplay, isNot(contains('Scrollable.ensureVisible(')));
      expect(
        lyricDisplay,
        contains('_scrollController.position.ensureVisible'),
      );
    },
  );

  test('mini player prepares artwork palette before opening the route', () {
    final miniPlayer = File(
      'lib/src/widgets/mini_player.dart',
    ).readAsStringSync();

    expect(miniPlayer, contains('final preparedPalette = ref.watch'));
    expect(miniPlayer, contains('preparedPalette.valueOrNull ??'));
    expect(miniPlayer, contains('playerVisualPaletteProvider('));
    expect(miniPlayer, contains(').future'));
    expect(
      miniPlayer.indexOf('final preparedPalette = ref.watch'),
      lessThan(miniPlayer.indexOf('return Dismissible(')),
    );
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
