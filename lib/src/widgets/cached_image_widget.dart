import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/cache_service.dart';
import '../services/storage_service.dart';
import '../utils/local_file_url.dart';

/// Displays local and remote images through the shared original-byte cache.
class CachedImageWidget extends StatelessWidget {
  const CachedImageWidget({
    super.key,
    required this.imageUrl,
    required this.hash,
    this.cacheKey,
    this.fit = BoxFit.contain,
  });

  final String imageUrl;
  final String hash;
  final String? cacheKey;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final localPath = LocalFileUrl.pathFromUrl(imageUrl);
    if (localPath != null) {
      final file = File(localPath);
      if (!file.existsSync()) return _buildErrorWidget(context, localPath);
      return Image.file(
        file,
        fit: fit,
        errorBuilder: (_, error, __) =>
            _buildErrorWidget(context, error.toString()),
      );
    }

    return CachedNetworkImage(
      imageUrl: imageUrl,
      cacheKey:
          cacheKey ??
          CacheService.imageCacheKey(imageUrl: imageUrl, hash: hash),
      cacheManager: CacheService.imageCacheManager,
      httpHeaders: StorageService.serverCookieHeaders,
      fit: fit,
      useOldImageOnUrlChange: true,
      progressIndicatorBuilder: (context, _, progress) {
        return Center(
          child: CircularProgressIndicator(value: progress.progress),
        );
      },
      errorWidget: (context, _, error) =>
          _buildErrorWidget(context, error.toString()),
    );
  }

  Widget _buildErrorWidget(BuildContext context, String error) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error, size: 64, color: Colors.red),
          const SizedBox(height: 16),
          Text(
            S.of(context).loadImageFailedWithError(error),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.red),
          ),
        ],
      ),
    );
  }
}
