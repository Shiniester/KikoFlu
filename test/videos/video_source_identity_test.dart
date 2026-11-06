import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_details_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'old video JSON defaults to MissAV and keeps its existing storage key',
    () {
      final video = VideoItem.fromJson({
        'id': 'shared-native-id',
        'title': 'Legacy video',
        'pageUrl': 'https://missav.ai/video/shared-native-id',
      });

      expect(video.sourceKey, 'missav');
      expect(video.storageKey, 'shared-native-id');
    },
  );

  test(
    'player verification falls back to the video page for either source',
    () {
      for (final video in [
        const VideoItem(
          id: 'missav-id',
          title: 'MissAV video',
          pageUrl: 'https://missav.ai/cn/video',
        ),
        const VideoItem(
          id: 'jable-id',
          sourceKey: 'jable',
          title: 'Jable video',
          pageUrl: 'https://jable.tv/videos/jable-id/',
        ),
      ]) {
        final verification = videoVerificationFor(video, null);

        expect(verification.sourceUrl, video.pageUrl);
        expect(verification.sourceKey, video.sourceKey);
      }
    },
  );

  test(
    'same native id has separate source storage and playback positions',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final library = VideoLibrary(preferences: preferences);
      await library.initialize();
      final missav = VideoItem.fromJson({
        'id': 'shared-native-id',
        'title': 'MissAV video',
        'pageUrl': 'https://missav.ai/video/shared-native-id',
      });
      final jable = VideoItem.fromJson({
        'id': 'shared-native-id',
        'sourceKey': 'jable',
        'title': 'Jable video',
        'pageUrl': 'https://jable.tv/videos/shared-native-id/',
      });

      await library.savePosition(
        missav.storageKey,
        const Duration(seconds: 11),
      );
      await library.savePosition(jable.storageKey, const Duration(seconds: 23));

      expect(missav.storageKey, 'shared-native-id');
      expect(jable.storageKey, 'jable:shared-native-id');
      expect(
        library.positionFor(missav.storageKey),
        const Duration(seconds: 11),
      );
      expect(
        library.positionFor(jable.storageKey),
        const Duration(seconds: 23),
      );
      expect(jsonDecode(preferences.getString('video_resume_positions_v1')!), {
        'shared-native-id': 11000,
        'jable:shared-native-id': 23000,
      });
      library.dispose();
    },
  );
}
