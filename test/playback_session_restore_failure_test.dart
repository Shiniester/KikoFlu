import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/playback_session_store.dart';

void main() {
  test(
    'failed playback session restoration clears stale player state',
    () async {
      var cleared = false;
      Object? reportedError;

      final restored = await runPlaybackSessionRestore(
        restore: () => Future<void>.error(StateError('media load failed')),
        clearOnFailure: () async {
          cleared = true;
        },
        onFailure: (error) {
          reportedError = error;
        },
      );

      expect(restored, isFalse);
      expect(cleared, isTrue);
      expect(reportedError, isA<StateError>());
    },
  );
}
