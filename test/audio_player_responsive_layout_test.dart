import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';

void main() {
  test('player switches to the dual-pane stage at 840 logical pixels', () {
    expect(usesWidePlayerLayout(839.9), isFalse);
    expect(usesWidePlayerLayout(840), isTrue);
    expect(usesWidePlayerLayout(1280), isTrue);
  });
}
