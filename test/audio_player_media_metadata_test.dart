import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
// ignore: depend_on_referenced_packages
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/playback_session_store.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_latest_request_test.dart' as player_fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('system media metadata uses translations and privacy settings', () async {
    SharedPreferences.setMockInitialValues({
      'server_host': 'https://example.invalid',
      'current_user': '{"name":"tester"}',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );

    final cacheRoot = await Directory.systemTemp.createTemp(
      'kiko-media-metadata-',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => cacheRoot.path,
    );

    final previousPlatform = AudioServicePlatform.instance;
    final recordingPlatform = _RecordingAudioService();
    AudioServicePlatform.instance = recordingPlatform;

    final service = AudioPlayerService.forTesting(
      _MetadataPlayer(),
      sessionStore: player_fixture.MemorySessionStore(),
      queueHistoryStore: _EmptyQueueHistoryStore(),
    );
    service.updatePreloadThreshold(null);
    var audioServiceInitialized = false;
    addTearDown(() async {
      try {
        await service.dispose();
      } finally {
        try {
          if (audioServiceInitialized) {
            await AudioService.cacheManager.dispose();
          }
        } finally {
          AudioServicePlatform.instance = previousPlatform;
          messenger.setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
          await recordingPlatform.mediaItems.close();
          await cacheRoot.delete(recursive: true);
        }
      }
    });

    await service.initialize();
    audioServiceInitialized = true;
    // Wait for async repository opening before teardown closes its JSON file.
    await AudioService.cacheManager.getFileFromCache('unused-test-key');

    const track = AudioTrack(
      id: 'translated-track',
      title: '原始标题',
      translatedTitle: '译名标题',
      url: 'https://example.invalid/audio.mp3',
      album: '原始专辑',
      translatedAlbum: '译名专辑',
    );

    final initialItem = recordingPlatform.nextMediaItem();
    await service.updateQueue([track]);
    _expectMetadata(
      await initialItem,
      title: '译名标题',
      album: '译名专辑',
    );

    final maskedItem = _updatePrivacyAndRead(
      service,
      recordingPlatform,
      enabled: true,
      maskTitle: true,
      customTitle: '私人播放',
    );
    _expectMetadata(
      await maskedItem,
      title: '私人播放',
      album: '原始专辑',
    );

    final changedCustomTitle = _updatePrivacyAndRead(
      service,
      recordingPlatform,
      enabled: true,
      maskTitle: true,
      customTitle: '正在播放',
    );
    _expectMetadata(
      await changedCustomTitle,
      title: '正在播放',
      album: '原始专辑',
    );

    final unmaskedItem = _updatePrivacyAndRead(
      service,
      recordingPlatform,
      enabled: true,
      maskTitle: false,
      customTitle: '正在播放',
    );
    _expectMetadata(
      await unmaskedItem,
      title: '译名标题',
      album: '译名专辑',
    );

    final restoredItem = _updatePrivacyAndRead(
      service,
      recordingPlatform,
      enabled: false,
      maskTitle: true,
      customTitle: '正在播放',
    );
    _expectMetadata(
      await restoredItem,
      title: '译名标题',
      album: '译名专辑',
    );

    expect(track.title, '原始标题');
    expect(track.album, '原始专辑');
    expect(service.currentTrack?.title, '原始标题');
    expect(service.currentTrack?.album, '原始专辑');
  });
}

Future<MediaItemMessage> _updatePrivacyAndRead(
  AudioPlayerService service,
  _RecordingAudioService platform, {
  required bool enabled,
  required bool maskTitle,
  required String customTitle,
}) async {
  final nextItem = platform.nextMediaItem();
  await service.updatePrivacySettings(
    enabled: enabled,
    blurCover: false,
    maskTitle: maskTitle,
    customTitle: customTitle,
  );
  return nextItem;
}

void _expectMetadata(
  MediaItemMessage item, {
  required String title,
  required String album,
}) {
  expect(item.title, title);
  expect(item.album, album);
}

class _RecordingAudioService extends NoOpAudioService {
  final mediaItems = StreamController<MediaItemMessage>.broadcast(sync: true);

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) {
    mediaItems.add(request.mediaItem);
    return super.setMediaItem(request);
  }

  Future<MediaItemMessage> nextMediaItem() => mediaItems.stream
      .first
      .timeout(const Duration(seconds: 5));
}

class _MetadataPlayer extends player_fixture.ControlledPlayer {
  @override
  double get speed => 1;
}

class _EmptyQueueHistoryStore implements PlaybackQueueHistoryStore {
  @override
  Future<List<PlaybackSessionSnapshot>> load() async => const [];

  @override
  Future<void> save(List<PlaybackSessionSnapshot> queues) async {}
}
