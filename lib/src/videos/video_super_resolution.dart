import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

enum VideoSuperResolution { off, efficiency, quality }

// iOS uses the software renderer to keep the same output alive in PiP.
bool get supportsVideoSuperResolution =>
    !kIsWeb && defaultTargetPlatform != TargetPlatform.iOS;

const _efficiencyShaders = [
  'Anime4K_Clamp_Highlights.glsl',
  'Anime4K_Restore_CNN_M.glsl',
  'Anime4K_Restore_CNN_S.glsl',
  'Anime4K_Upscale_CNN_x2_M.glsl',
  'Anime4K_AutoDownscalePre_x2.glsl',
  'Anime4K_AutoDownscalePre_x4.glsl',
  'Anime4K_Upscale_CNN_x2_S.glsl',
];

const _qualityShaders = [
  'Anime4K_Clamp_Highlights.glsl',
  'Anime4K_Restore_CNN_VL.glsl',
  'Anime4K_Upscale_CNN_x2_VL.glsl',
  'Anime4K_AutoDownscalePre_x2.glsl',
  'Anime4K_AutoDownscalePre_x4.glsl',
  'Anime4K_Upscale_CNN_x2_M.glsl',
];

Future<void> applyVideoSuperResolution(
  Player player,
  VideoSuperResolution mode,
) async {
  final native = player.platform;
  if (native is! NativePlayer) {
    throw UnsupportedError('Video shaders require the native video player');
  }
  if (mode == VideoSuperResolution.off) {
    await native.command(const ['change-list', 'glsl-shaders', 'clr', '']);
    return;
  }
  if (!supportsVideoSuperResolution) {
    throw UnsupportedError('Video shaders require a GPU video renderer');
  }
  final shaders = mode == VideoSuperResolution.efficiency
      ? _efficiencyShaders
      : _qualityShaders;
  final support = await getApplicationSupportDirectory();
  final directory = Directory(path.join(support.path, 'video_shaders'));
  await directory.create(recursive: true);
  for (final shader in shaders) {
    final data = await rootBundle.load('assets/shaders/$shader');
    await File(path.join(directory.path, shader)).writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }
  await native.command([
    'change-list',
    'glsl-shaders',
    'set',
    shaders
        .map((shader) => path.join(directory.path, shader))
        .join(Platform.isWindows ? ';' : ':'),
  ]);
}
