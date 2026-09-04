import 'dart:ui' as ui;
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'dart:convert';

import 'local_file_url.dart';
import '../services/cache_service.dart';
import '../services/remote_asset_cache.dart';
import '../services/storage_service.dart';

/// 图片模糊处理工具类
class ImageBlurUtil {
  /// 对网络图片或本地图片应用高强度高斯模糊并保存到临时文件
  /// 返回模糊后的图片文件路径（file:// 协议）
  static Future<String?> blurNetworkImageToFile(
    String imageUrl, {
    String? cacheKey,
  }) async {
    try {
      final localPath = LocalFileUrl.pathFromUrl(imageUrl);
      final imageUri = localPath == null ? Uri.parse(imageUrl) : null;
      final canonicalUri = imageUri == null
          ? null
          : RemoteAssetKey.canonicalUri(imageUri);
      final kind = cacheKey?.startsWith('work_cover_') == true
          ? RemoteAssetKind.workCover
          : RemoteAssetKind.contentImage;
      final stableSource =
          localPath ??
          '${CacheService.remoteAssetKey(kind: kind, identity: cacheKey ?? canonicalUri!).canonical}\u0000$canonicalUri';
      final urlHash = md5
          .convert(utf8.encode('$stableSource|blur=100|version=1'))
          .toString();
      final cacheDirectory = await CacheService.getDerivedImageCacheDirectory();
      final blurredFile = File(
        p.join(cacheDirectory.path, 'blurred_$urlHash.png'),
      );

      // 如果已经存在模糊后的文件，直接返回
      if (await blurredFile.exists()) {
        return LocalFileUrl.fromPath(blurredFile.path);
      }

      Uint8List imageData;

      // 判断是本地文件还是网络URL
      if (localPath != null) {
        // 本地文件
        final localFile = File(localPath);
        if (!await localFile.exists()) {
          debugPrint('本地图片文件不存在: $localPath');
          return null;
        }
        imageData = await localFile.readAsBytes();
      } else {
        final lease = CacheService.imageCacheManager.acquireFile(
          imageUrl,
          key: cacheKey,
          headers: StorageService.serverCookieHeaders,
        );
        try {
          final cachedFile = await lease.file.timeout(
            const Duration(seconds: 30),
          );
          imageData = await cachedFile.readAsBytes();
        } finally {
          await lease.release();
        }
      }

      // 解码图片
      final ui.Codec codec = await ui.instantiateImageCodec(imageData);
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ui.Image image = frameInfo.image;

      ui.Picture? picture;
      ui.Image? blurredImage;
      try {
        // 应用极高强度模糊 (sigma = 100)
        final ui.PictureRecorder recorder = ui.PictureRecorder();
        final Canvas canvas = Canvas(recorder);

        // 创建高斯模糊滤镜
        final Paint paint = Paint()
          ..imageFilter = ui.ImageFilter.blur(sigmaX: 100.0, sigmaY: 100.0);

        // 绘制模糊图片
        canvas.drawImage(image, Offset.zero, paint);

        // 转换为图片
        picture = recorder.endRecording();
        blurredImage = await picture.toImage(image.width, image.height);

        // 转换为PNG字节数据
        final ByteData? byteData = await blurredImage.toByteData(
          format: ui.ImageByteFormat.png,
        );

        if (byteData == null) {
          return null;
        }

        final Uint8List pngBytes = byteData.buffer.asUint8List();

        // 保存到临时文件
        await blurredFile.writeAsBytes(pngBytes);

        return LocalFileUrl.fromPath(blurredFile.path);
      } finally {
        image.dispose();
        picture?.dispose();
        blurredImage?.dispose();
      }
    } catch (e) {
      debugPrint('模糊图片失败: $e');
      return null;
    }
  }
}
