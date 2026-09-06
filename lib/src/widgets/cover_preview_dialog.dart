import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:saver_gallery/saver_gallery.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:path/path.dart' as p;

import '../utils/snackbar_util.dart';
import '../services/storage_service.dart';
import '../services/cache_service.dart';
import 'privacy_blur_cover.dart';
import 'player/player_visual_palette.dart';
import 'player/player_cover_widget.dart';
import '../../l10n/app_localizations.dart';

const _coverImageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};

String playerCoverPreviewHeroTag(String trackId) =>
    'player_cover_preview_$trackId';

String resolveCoverImageExtension({String? source, required Uint8List bytes}) {
  if (source != null && source.isNotEmpty) {
    final path = Uri.tryParse(source)?.path ?? source;
    final extension = p.extension(path).replaceFirst('.', '').toLowerCase();
    if (_coverImageExtensions.contains(extension)) return extension;
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'jpg';
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    return 'webp';
  }
  if (bytes.length >= 3 && String.fromCharCodes(bytes.sublist(0, 3)) == 'GIF') {
    return 'gif';
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4d) {
    return 'bmp';
  }
  return 'jpg';
}

/// 封面预览对话框，支持放大查看和保存图片
class CoverPreviewDialog extends StatefulWidget {
  static const double fallbackAspectRatio = 4 / 3;
  static const double cornerRadius = 12;

  /// 网络图片URL
  final String? imageUrl;

  /// 本地图片路径
  final String? localPath;

  /// 用于生成保存文件名的标识
  final String? identifier;

  /// Hero标签（用于动画过渡）
  final String? heroTag;

  /// 与列表、详情和保存操作共享的稳定原图缓存键。
  final String? cacheKey;

  /// 与当前播放器调色板一致的最深背景色。
  final Color backgroundColor;

  /// 当前播放器封面页使用的完整渐变调色板。
  final PlayerVisualPalette? backgroundPalette;

  /// Decoded aspect ratio used to size the Hero destination.
  final double imageAspectRatio;

  /// Route animation used only for the preview background.
  final Animation<double>? routeAnimation;

  const CoverPreviewDialog({
    super.key,
    this.imageUrl,
    this.localPath,
    this.identifier,
    this.heroTag,
    this.cacheKey,
    this.backgroundColor = Colors.black,
    this.backgroundPalette,
    this.imageAspectRatio = fallbackAspectRatio,
    this.routeAnimation,
  }) : assert(
         imageUrl != null || localPath != null,
         'Either imageUrl or localPath must be provided',
       );

  /// 显示封面预览对话框
  static Future<void> show(
    BuildContext context, {
    String? imageUrl,
    String? localPath,
    String? identifier,
    String? heroTag,
    String? cacheKey,
    Color backgroundColor = Colors.black,
    PlayerVisualPalette? backgroundPalette,
  }) async {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final imageAspectRatio = await _resolveImageAspectRatio(
      context,
      imageUrl: imageUrl,
      localPath: localPath,
      cacheKey: cacheKey,
    );
    if (!context.mounted) return;
    await Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.transparent,
        transitionDuration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 280),
        reverseTransitionDuration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 280),
        pageBuilder: (context, animation, secondaryAnimation) {
          return CoverPreviewDialog(
            imageUrl: imageUrl,
            localPath: localPath,
            identifier: identifier,
            heroTag: heroTag,
            cacheKey: cacheKey,
            backgroundColor: backgroundColor,
            backgroundPalette: backgroundPalette,
            imageAspectRatio: imageAspectRatio,
            routeAnimation: animation,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            child,
      ),
    );
  }

  static Future<double> _resolveImageAspectRatio(
    BuildContext context, {
    String? imageUrl,
    String? localPath,
    String? cacheKey,
  }) async {
    ImageProvider<Object>? provider;
    if (localPath != null && File(localPath).existsSync()) {
      provider = FileImage(File(localPath));
    } else if (imageUrl != null) {
      provider = CachedNetworkImageProvider(
        imageUrl,
        cacheKey: cacheKey,
        cacheManager: CacheService.imageCacheManager,
        headers: StorageService.serverCookieHeaders,
      );
    }
    if (provider == null) return fallbackAspectRatio;

    final completer = Completer<double>();
    final stream = provider.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (imageInfo, synchronousCall) {
        final width = imageInfo.image.width;
        final height = imageInfo.image.height;
        if (!completer.isCompleted) {
          completer.complete(
            width > 0 && height > 0 ? width / height : fallbackAspectRatio,
          );
        }
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!completer.isCompleted) completer.complete(fallbackAspectRatio);
      },
    );
    stream.addListener(listener);
    try {
      return await completer.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () => fallbackAspectRatio,
      );
    } finally {
      stream.removeListener(listener);
    }
  }

  @override
  State<CoverPreviewDialog> createState() => _CoverPreviewDialogState();
}

class _CoverPreviewDialogState extends State<CoverPreviewDialog> {
  final TransformationController _transformController =
      TransformationController();
  final Set<int> _activePointers = <int>{};
  bool _isSaving = false;
  bool _pointerMoved = false;
  bool _multiTouch = false;
  bool _longPressTriggered = false;
  Offset? _pointerDownPosition;
  Offset? _pendingTapPosition;
  Timer? _longPressTimer;
  Timer? _singleTapTimer;

  String? get _cacheKey {
    if (widget.cacheKey != null) return widget.cacheKey;
    final identifier = widget.identifier;
    return identifier != null && int.tryParse(identifier) != null
        ? 'work_cover_$identifier'
        : null;
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _singleTapTimer?.cancel();
    _transformController.dispose();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    _activePointers.add(event.pointer);
    if (_activePointers.length == 1) {
      _pointerDownPosition = event.position;
      _pointerMoved = false;
      _multiTouch = false;
      _longPressTriggered = false;
      _longPressTimer?.cancel();
      _longPressTimer = Timer(kLongPressTimeout, () {
        if (!mounted || _activePointers.length != 1 || _pointerMoved) return;
        _longPressTriggered = true;
        unawaited(_saveImage());
      });
      return;
    }
    _multiTouch = true;
    _longPressTimer?.cancel();
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final downPosition = _pointerDownPosition;
    if (downPosition == null ||
        (event.position - downPosition).distance <= kTouchSlop) {
      return;
    }
    _pointerMoved = true;
    _longPressTimer?.cancel();
  }

  void _handlePointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isNotEmpty) return;
    _longPressTimer?.cancel();
    if (!_multiTouch && !_pointerMoved && !_longPressTriggered) {
      _registerTap(event.position);
    }
    _resetPointerGesture();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isEmpty) {
      _longPressTimer?.cancel();
      _resetPointerGesture();
    }
  }

  void _resetPointerGesture() {
    _pointerDownPosition = null;
    _pointerMoved = false;
    _multiTouch = false;
    _longPressTriggered = false;
  }

  void _registerTap(Offset position) {
    final pendingPosition = _pendingTapPosition;
    if (_singleTapTimer?.isActive == true &&
        pendingPosition != null &&
        (position - pendingPosition).distance <= kDoubleTapSlop) {
      _singleTapTimer!.cancel();
      _pendingTapPosition = null;
      _handleDoubleTap();
      return;
    }
    _singleTapTimer?.cancel();
    _pendingTapPosition = position;
    _singleTapTimer = Timer(kDoubleTapTimeout, () {
      _pendingTapPosition = null;
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _handleDoubleTap() {
    final currentScale = _transformController.value.getMaxScaleOnAxis();

    if (currentScale > 1.0) {
      _transformController.value = Matrix4.identity();
    } else {
      const newScale = 2.5;
      _transformController.value = Matrix4.identity()
        ..scaleByDouble(newScale, newScale, newScale, 1);
    }
  }

  Future<void> _saveImage() async {
    if (_isSaving) return;

    setState(() => _isSaving = true);

    try {
      final Uint8List imageBytes;
      final String source;

      if (widget.localPath != null && File(widget.localPath!).existsSync()) {
        imageBytes = await File(widget.localPath!).readAsBytes();
        source = widget.localPath!;
      } else if (widget.imageUrl != null) {
        final lease = CacheService.imageCacheManager.acquireFile(
          widget.imageUrl!,
          key: _cacheKey,
          headers: StorageService.serverCookieHeaders,
        );
        try {
          imageBytes = await (await lease.file).readAsBytes();
        } finally {
          await lease.release();
        }
        source = widget.imageUrl!;
      } else {
        throw Exception(S.of(context).noImageAvailable);
      }
      final extension = resolveCoverImageExtension(
        source: source,
        bytes: imageBytes,
      );
      final safeIdentifier =
          (widget.identifier ??
                  DateTime.now().millisecondsSinceEpoch.toString())
              .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      final fileName = 'cover_$safeIdentifier.$extension';

      // 根据平台选择保存方式
      if (Platform.isAndroid || Platform.isIOS) {
        await _saveToGallery(imageBytes, fileName);
      } else {
        await _saveToFile(imageBytes, fileName);
      }
    } catch (e) {
      if (mounted) {
        SnackBarUtil.showError(
          context,
          S.of(context).saveFailedWithError(e.toString()),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _saveToGallery(Uint8List bytes, String fileName) async {
    // 请求权限
    if (Platform.isAndroid) {
      final status = await Permission.photos.request();
      if (!status.isGranted) {
        final storageStatus = await Permission.storage.request();
        if (!storageStatus.isGranted) {
          if (mounted) {
            SnackBarUtil.showError(
              context,
              S.of(context).storagePermissionRequiredForImage,
            );
          }
          return;
        }
      }
    }

    final result = await SaverGallery.saveImage(
      bytes,
      fileName: fileName,
      androidRelativePath: 'Pictures/KikoFlu',
      skipIfExists: false,
    );

    if (mounted) {
      if (result.isSuccess) {
        SnackBarUtil.showSuccess(context, S.of(context).savedToGallery);
      } else {
        SnackBarUtil.showError(context, S.of(context).saveImageFailed);
      }
    }
  }

  Future<void> _saveToFile(Uint8List bytes, String fileName) async {
    // 桌面端：让用户选择保存位置
    final result = await FilePicker.platform.saveFile(
      dialogTitle: S.of(context).saveCoverImage,
      fileName: fileName,
      type: FileType.image,
    );

    if (result != null) {
      final file = File(result);
      await file.writeAsBytes(bytes);
      if (mounted) {
        SnackBarUtil.showSuccess(context, S.of(context).savedToPath(result));
      }
    }
  }

  Widget _buildImage({BoxFit fit = BoxFit.cover, bool includeHero = true}) {
    Widget imageWidget;

    if (widget.localPath != null && File(widget.localPath!).existsSync()) {
      imageWidget = Image.file(
        File(widget.localPath!),
        fit: fit,
        errorBuilder: (context, error, stackTrace) {
          if (widget.imageUrl != null) {
            return CachedNetworkImage(
              imageUrl: widget.imageUrl!,
              cacheKey: _cacheKey,
              cacheManager: CacheService.imageCacheManager,
              httpHeaders: StorageService.serverCookieHeaders,
              fit: fit,
              placeholder: (context, url) =>
                  const Center(child: CircularProgressIndicator()),
              errorWidget: (context, url, error) =>
                  const Icon(Icons.error, color: Colors.white, size: 48),
            );
          }
          return const Icon(Icons.error, color: Colors.white, size: 48);
        },
      );
    } else if (widget.imageUrl != null) {
      imageWidget = CachedNetworkImage(
        imageUrl: widget.imageUrl!,
        cacheKey: _cacheKey,
        cacheManager: CacheService.imageCacheManager,
        httpHeaders: StorageService.serverCookieHeaders,
        fit: fit,
        placeholder: (context, url) =>
            const Center(child: CircularProgressIndicator()),
        errorWidget: (context, url, error) =>
            const Icon(Icons.error, color: Colors.white, size: 48),
      );
    } else {
      imageWidget = const Icon(
        Icons.image_not_supported,
        color: Colors.white,
        size: 48,
      );
    }

    Widget result = PrivacyBlurCover(child: imageWidget);
    if (includeHero && widget.heroTag != null) {
      result = PlayerCoverPreviewHero(
        tag: widget.heroTag!,
        cornerRadius: CoverPreviewDialog.cornerRadius,
        flightChild: _buildImage(includeHero: false),
        child: result,
      );
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.backgroundPalette;
    Widget background = ColoredBox(color: widget.backgroundColor);
    if (palette != null) {
      background = DecoratedBox(
        key: const ValueKey('cover-preview-linear-background'),
        decoration: BoxDecoration(gradient: palette.backgroundGradient),
        child: DecoratedBox(
          key: const ValueKey('cover-preview-radial-background'),
          decoration: BoxDecoration(gradient: palette.accentGradient),
        ),
      );
    }
    final routeAnimation = widget.routeAnimation;
    if (routeAnimation != null) {
      background = FadeTransition(
        opacity: CurvedAnimation(
          parent: routeAnimation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        ),
        child: background,
      );
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: background),
              Positioned.fill(
                child: Listener(
                  key: const ValueKey('cover-preview-background'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _handlePointerDown,
                  onPointerMove: _handlePointerMove,
                  onPointerUp: _handlePointerUp,
                  onPointerCancel: _handlePointerCancel,
                  child: InteractiveViewer(
                    key: const ValueKey('cover-preview-interactive-viewer'),
                    transformationController: _transformController,
                    minScale: 1.0,
                    maxScale: 5.0,
                    clipBehavior: Clip.none,
                    child: SafeArea(
                      minimum: const EdgeInsets.all(16),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final aspectRatio = widget.imageAspectRatio > 0
                              ? widget.imageAspectRatio
                              : CoverPreviewDialog.fallbackAspectRatio;
                          final width = math.min(
                            constraints.maxWidth,
                            constraints.maxHeight * aspectRatio,
                          );
                          final height = width / aspectRatio;
                          return Center(
                            child: SizedBox(
                              key: const ValueKey('cover-preview-image-frame'),
                              width: width,
                              height: height,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  CoverPreviewDialog.cornerRadius,
                                ),
                                child: KeyedSubtree(
                                  key: const ValueKey('cover-preview-image'),
                                  child: _buildImage(),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
