import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/src/pending_load.dart';

void main() {
  test('desktop media open errors fail the awaited just_audio load', () async {
    final pendingLoad = MediaKitPendingLoad();
    final expectation = expectLater(
      pendingLoad.future,
      throwsA(
        isA<PlatformException>()
            .having((error) => error.code, 'code', '1')
            .having(
              (error) => error.message,
              'message',
              'Failed to open media',
            ),
      ),
    );

    pendingLoad.fail('Failed to open media');

    await expectation;
  });
}
