import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/storage_service.dart';
import 'jable_client.dart';
import 'jable_verification.dart';
import 'missav_client.dart';
import 'missav_verification.dart';
import 'video_downloads.dart';
import 'video_library.dart';
import 'video_source_client.dart';

class VideoSourceOption {
  const VideoSourceOption({required this.key, required this.name});

  final String key;
  final String name;
}

const videoSourceOptions = [
  VideoSourceOption(key: 'missav', name: 'MissAV'),
  VideoSourceOption(key: 'jable', name: 'Jable'),
];

final videoSelectedSourceProvider = StateProvider<String>((ref) {
  final saved = StorageService.getString('video_selected_source');
  return videoSourceOptions.any((source) => source.key == saved)
      ? saved!
      : 'missav';
});

final videoClientProvider = ChangeNotifierProvider<MissavClient>(
  (ref) => MissavClient(restoreSavedSession: restoreMissavBrowserSession),
);

final jableVideoClientProvider = Provider<JableClient>((ref) {
  final client = JableClient(restoreSavedSession: restoreJableBrowserSession);
  ref.onDispose(client.dispose);
  return client;
});

final jableAccessVerifierProvider = Provider((ref) => verifyJableAccess);

final videoSourceClientProvider = Provider.family<VideoSourceClient, String>(
  (ref, sourceKey) => switch (sourceKey) {
    'jable' => ref.watch(jableVideoClientProvider),
    _ => ref.watch(videoClientProvider),
  },
);

final videoBrowserSessionCleanupProvider = Provider<Future<void> Function()>(
  (ref) => clearMissavBrowserSession,
);

final videoLibraryProvider = ChangeNotifierProvider<VideoLibrary>(
  (ref) => VideoLibrary(),
);

final videoDownloadsProvider = ChangeNotifierProvider<VideoDownloads>(
  (ref) => VideoDownloads(
    client: ref.read(videoClientProvider),
    sourceClientFor: (sourceKey) =>
        ref.read(videoSourceClientProvider(sourceKey)),
    library: ref.read(videoLibraryProvider),
  ),
);
