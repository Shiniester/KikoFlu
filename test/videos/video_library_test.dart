import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/src/videos/video_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'resume positions and video volume survive reopening on this device',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final library = VideoLibrary(preferences: preferences);
      await library.initialize();

      await library.savePosition(
        'video-a',
        const Duration(minutes: 2, seconds: 3),
      );
      await library.savePosition('video-b', const Duration(seconds: 19));
      await library.setVolume(37.5);
      library.dispose();

      final restored = VideoLibrary(preferences: preferences);
      await restored.initialize();
      expect(
        restored.positionFor('video-a'),
        const Duration(minutes: 2, seconds: 3),
      );
      expect(restored.positionFor('video-b'), const Duration(seconds: 19));
      expect(restored.positionFor('unknown'), Duration.zero);
      expect(restored.volume, 37.5);
      restored.dispose();
    },
  );

  test('video volume stays within the media-kit range', () async {
    SharedPreferences.setMockInitialValues({});
    final library = VideoLibrary(
      preferences: await SharedPreferences.getInstance(),
    );
    await library.initialize();

    await library.setVolume(140);
    expect(library.volume, 100);
    await library.setVolume(-10);
    expect(library.volume, 0);
    library.dispose();
  });
}
