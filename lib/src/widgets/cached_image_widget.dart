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
    this.onRetry,
    this.cacheWidth,
    this.onAspectRatio,
    this.onImageError,
  });

  final String imageUrl;
  final String hash;
  final String? cacheKey;
  final BoxFit fit;
  final VoidCallback? onRetry;
  final int? cacheWidth;
  final ValueChanged<double>? onAspectRatio;
  final VoidCallback? onImageError;

  @override
  Widget build(BuildContext context) {
    final localPath = LocalFileUrl.pathFromUrl(imageUrl);
    if (localPath != null) {
      final file = File(localPath);
      if (!file.existsSync()) return _buildErrorWidget(context, localPath);
      if (onAspectRatio != null) {
        final imageProvider = ResizeImage.resizeIfNeeded(
          cacheWidth,
          null,
          FileImage(file),
        );
        return _ImageAspectRatioReporter(
          imageProvider: imageProvider,
          onAspectRatio: onAspectRatio!,
          onImageError: onImageError,
          child: Image(
            image: imageProvider,
            fit: fit,
            errorBuilder: (_, error, __) =>
                _buildErrorWidget(context, error.toString()),
          ),
        );
      }
      return Image.file(
        file,
        cacheWidth: cacheWidth,
        fit: fit,
        errorBuilder: (_, error, __) =>
            _buildErrorWidget(context, error.toString()),
      );
    }

    return CachedNetworkImage(
      memCacheWidth: cacheWidth,
      imageUrl: imageUrl,
      cacheKey:
          cacheKey ??
          CacheService.imageCacheKey(imageUrl: imageUrl, hash: hash),
      cacheManager: CacheService.imageCacheManager,
      httpHeaders: StorageService.serverCookieHeaders,
      fit: fit,
      useOldImageOnUrlChange: true,
      imageBuilder: onAspectRatio == null
          ? null
          : (context, imageProvider) {
              final resizedProvider = ResizeImage.resizeIfNeeded(
                cacheWidth,
                null,
                imageProvider,
              );
              return _ImageAspectRatioReporter(
                imageProvider: resizedProvider,
                onAspectRatio: onAspectRatio!,
                onImageError: onImageError,
                child: Image(
                  image: resizedProvider,
                  fit: fit,
                  gaplessPlayback: true,
                ),
              );
            },
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
    _reportImageError();
    if (onRetry != null) {
      return SizedBox(
        height: 100,
        child: Center(
          child: IconButton(
            tooltip: S.of(context).retry,
            icon: const Icon(Icons.broken_image_outlined),
            onPressed: onRetry,
          ),
        ),
      );
    }
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

  void _reportImageError() {
    final callback = onImageError;
    if (callback != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => callback());
    }
  }
}

class _ImageAspectRatioReporter extends StatefulWidget {
  const _ImageAspectRatioReporter({
    required this.imageProvider,
    required this.onAspectRatio,
    this.onImageError,
    required this.child,
  });

  final ImageProvider imageProvider;
  final ValueChanged<double> onAspectRatio;
  final VoidCallback? onImageError;
  final Widget child;

  @override
  State<_ImageAspectRatioReporter> createState() =>
      _ImageAspectRatioReporterState();
}

class _ImageAspectRatioReporterState extends State<_ImageAspectRatioReporter> {
  ImageStream? _imageStream;
  ImageStreamListener? _listener;
  int _generation = 0;

  void _listenForDimensions() {
    _generation++;
    if (_imageStream != null && _listener != null) {
      _imageStream!.removeListener(_listener!);
    }
    final generation = _generation;
    final stream = widget.imageProvider.resolve(
      createLocalImageConfiguration(context),
    );
    final listener = ImageStreamListener(
      (info, synchronousCall) {
        final aspectRatio = info.image.width / info.image.height;
        info.dispose();
        void report() {
          if (mounted && generation == _generation) {
            widget.onAspectRatio(aspectRatio);
          }
        }

        if (synchronousCall) {
          WidgetsBinding.instance.addPostFrameCallback((_) => report());
        } else {
          report();
        }
      },
      onError: (error, stackTrace) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _generation) {
            widget.onImageError?.call();
          }
        });
      },
    );
    _imageStream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listenForDimensions();
  }

  @override
  void didUpdateWidget(_ImageAspectRatioReporter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageProvider != widget.imageProvider ||
        oldWidget.onAspectRatio != widget.onAspectRatio ||
        oldWidget.onImageError != widget.onImageError) {
      _listenForDimensions();
    }
  }

  @override
  void dispose() {
    _generation++;
    if (_imageStream != null && _listener != null) {
      _imageStream!.removeListener(_listener!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
