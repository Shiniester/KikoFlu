import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android uses media_kit for audio and keeps Media3 for video', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final serviceSource = File(
      'lib/src/services/audio_player_service.dart',
    ).readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final androidBuild = File(
      'android/app/build.gradle.kts',
    ).readAsStringSync();

    expect(
      mainSource,
      matches(
        RegExp(
          r'JustAudioMediaKit\.ensureInitialized\((?=[^)]*android\s*:\s*true)(?=[^)]*iOS\s*:\s*true)(?=[^)]*macOS\s*:\s*true)[^)]*\)',
          dotAll: true,
        ),
      ),
      reason: 'Audio players must use the common media_kit backend.',
    );
    expect(
      pubspec,
      matches(
        RegExp(
          r'media_kit_libs_android_video:\s*\n\s+path:\s*third_party/media_kit_libs_android_video',
        ),
      ),
    );
    expect(
      serviceSource,
      contains('androidApplyAudioAttributes: false'),
      reason: 'media_kit does not implement Media3 audio attribute updates.',
    );
    expect(serviceSource, isNot(contains('AndroidLoudnessEnhancer')));
    expect(androidBuild, contains('val media3Version = "1.8.0"'));
    expect(
      androidBuild,
      contains(
        'implementation("androidx.media3:media3-exoplayer:\$media3Version")',
      ),
    );
  });
}
