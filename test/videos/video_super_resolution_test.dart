import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/videos/video_super_resolution.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  test(
    'iOS rejects GPU shaders while still allowing the default disabled mode',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final player = _ShaderPlayer();
      expect(supportsVideoSuperResolution, isFalse);
      await expectLater(
        applyVideoSuperResolution(player, VideoSuperResolution.efficiency),
        throwsUnsupportedError,
      );
      expect(player.native.commands, isEmpty);
      await applyVideoSuperResolution(player, VideoSuperResolution.off);
      expect(player.native.commands, [
        ['change-list', 'glsl-shaders', 'clr', ''],
      ]);
    },
  );
}

class _ShaderPlayer extends Fake implements Player {
  final native = _ShaderNativePlayer();

  @override
  NativePlayer get platform => native;
}

class _ShaderNativePlayer extends Fake implements NativePlayer {
  final commands = <List<String>>[];

  @override
  Future<void> command(
    List<String> command, {
    bool waitForInitialization = true,
  }) async {
    commands.add(command);
  }
}
