import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';

void main() {
  test('taller windows switch to the dual-pane stage at 840 pixels', () {
    expect(usesWidePlayerLayout(839.9, height: 720), isFalse);
    expect(usesWidePlayerLayout(840, height: 720), isTrue);
    expect(usesWidePlayerLayout(1280, height: 720), isTrue);
  });
}
