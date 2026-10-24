import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'missav_client.dart';
import 'missav_verification.dart';
import 'video_downloads.dart';
import 'video_library.dart';

final videoClientProvider = ChangeNotifierProvider<MissavClient>(
  (ref) => MissavClient(restoreSavedSession: restoreMissavBrowserSession),
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
    library: ref.read(videoLibraryProvider),
  ),
);
