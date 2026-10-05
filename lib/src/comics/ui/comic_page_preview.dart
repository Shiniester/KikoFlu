import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../../l10n/app_localizations.dart';

class ComicPagePreview extends StatefulWidget {
  const ComicPagePreview({
    super.key,
    required this.pageCount,
    required this.initialPage,
    required this.title,
    required this.scrollController,
    required this.loadImage,
    required this.onSelected,
  });

  final int pageCount;
  final int initialPage;
  final String title;
  final ScrollController scrollController;
  final Future<Uint8List> Function(int) loadImage;
  final ValueChanged<int> onSelected;

  @override
  State<ComicPagePreview> createState() => _ComicPagePreviewState();
}

class _ComicPagePreviewState extends State<ComicPagePreview> {
  static const _tileExtent = 182.0;
  static const _tileSpacing = 10.0;
  static const _cacheLimit = 64;
  static const _maxConcurrentLoads = 3;

  final Queue<int> _queue = Queue<int>();
  final Set<int> _queued = {};
  final Set<int> _activeTiles = {};
  final Set<int> _inFlight = {};
  final Map<int, ({int width, int height})> _tileSizes = {};
  final Map<int, ({int width, int height})> _queuedSizes = {};
  final LinkedHashMap<int, Uint8List> _thumbnails = LinkedHashMap();
  final Map<int, Object> _errors = {};

  late final int _page = widget.pageCount <= 0
      ? 0
      : widget.initialPage.clamp(0, widget.pageCount - 1).toInt();
  int _running = 0;
  bool _ready = false;
  bool _positionScheduled = false;
  bool _accepting = true;
  Animation<double>? _routeAnimation;
  AnimationStatusListener? _routeStatusListener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _routeAnimation)) return;
    if (_routeAnimation != null && _routeStatusListener != null) {
      _routeAnimation!.removeStatusListener(_routeStatusListener!);
    }
    _routeAnimation = animation;
    if (animation == null) return;
    _routeStatusListener = (status) {
      if (status == AnimationStatus.reverse ||
          status == AnimationStatus.dismissed) {
        _stopAccepting();
      }
    };
    animation.addStatusListener(_routeStatusListener!);
  }

  @override
  void dispose() {
    _stopAccepting();
    if (_routeAnimation != null && _routeStatusListener != null) {
      _routeAnimation!.removeStatusListener(_routeStatusListener!);
    }
    super.dispose();
  }

  void _stopAccepting() {
    if (!_accepting) return;
    _accepting = false;
    _queue.clear();
    _queued.clear();
    _queuedSizes.clear();
    _activeTiles.clear();
  }

  Uint8List? _thumbnail(int index) {
    final value = _thumbnails.remove(index);
    if (value != null) _thumbnails[index] = value;
    return value;
  }

  void _activate(int index, int width, int height) {
    _activeTiles.add(index);
    _tileSizes[index] = (width: width, height: height);
    if (_thumbnail(index) == null) _enqueue(index);
  }

  void _deactivate(int index) {
    _activeTiles.remove(index);
    _trimThumbnails();
    _tileSizes.remove(index);
    _errors.remove(index);
    if (_queued.remove(index)) {
      _queue.remove(index);
      _queuedSizes.remove(index);
    }
  }

  void _trimThumbnails() {
    for (final index in _thumbnails.keys.toList()) {
      if (_thumbnails.length <= _cacheLimit) break;
      if (!_activeTiles.contains(index)) _thumbnails.remove(index);
    }
  }

  void _enqueue(int index) {
    if (!_accepting ||
        !_ready ||
        !_activeTiles.contains(index) ||
        _inFlight.contains(index) ||
        _queued.contains(index) ||
        _errors.containsKey(index) ||
        _thumbnails.containsKey(index)) {
      return;
    }
    final size = _tileSizes[index];
    if (size == null) return;
    _queued.add(index);
    _queuedSizes[index] = size;
    _queue.add(index);
    _drainQueue();
  }

  void _drainQueue() {
    while (_accepting &&
        _ready &&
        _running < _maxConcurrentLoads &&
        _queue.isNotEmpty) {
      final index = _queue.removeFirst();
      _queued.remove(index);
      final size = _queuedSizes.remove(index);
      if (!_activeTiles.contains(index) || size == null) continue;
      _inFlight.add(index);
      _running++;
      unawaited(_loadThumbnail(index, size));
    }
  }

  Future<void> _loadThumbnail(int index, ({int width, int height}) size) async {
    try {
      final bytes = await widget.loadImage(index);
      final thumbnail = await _decodeThumbnail(bytes, size.width, size.height);
      if (mounted && _accepting && _activeTiles.contains(index)) {
        setState(() {
          _errors.remove(index);
          _thumbnails.remove(index);
          _thumbnails[index] = thumbnail;
          _trimThumbnails();
        });
      }
    } catch (error) {
      if (mounted && _accepting && _activeTiles.contains(index)) {
        setState(() => _errors[index] = error);
      }
    } finally {
      _inFlight.remove(index);
      _running--;
      if (mounted && _accepting) _drainQueue();
    }
  }

  Future<Uint8List> _decodeThumbnail(
    Uint8List bytes,
    int width,
    int height,
  ) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final widthScale = width / descriptor.width;
        final heightScale = height / descriptor.height;
        final scale = widthScale < heightScale ? widthScale : heightScale;
        final resizeWidth = scale < 1 && widthScale <= heightScale;
        final codec = await descriptor.instantiateCodec(
          targetWidth: resizeWidth ? width : null,
          targetHeight: scale < 1 && !resizeWidth ? height : null,
        );
        try {
          final frame = await codec.getNextFrame();
          try {
            final data = await frame.image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            if (data == null) {
              throw StateError('Could not encode page preview');
            }
            return Uint8List.view(
              data.buffer,
              data.offsetInBytes,
              data.lengthInBytes,
            );
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  void _retry(int index) {
    if (!_accepting) return;
    setState(() => _errors.remove(index));
    _enqueue(index);
  }

  void _select(int index) {
    if (!_accepting || !_thumbnails.containsKey(index)) return;
    _stopAccepting();
    widget.onSelected(index);
  }

  void _close() {
    if (!_accepting) return;
    final navigator = Navigator.of(context);
    _stopAccepting();
    navigator.pop();
  }

  void _positionGrid(int columns) {
    if (_positionScheduled || _ready || !_accepting) return;
    _positionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_accepting || _ready) {
        _positionScheduled = false;
        return;
      }
      final controller = widget.scrollController;
      if (!controller.hasClients) {
        _positionScheduled = false;
        return;
      }
      final position = controller.position;
      final row = _page ~/ columns;
      final target = (8 + row * (_tileExtent + _tileSpacing))
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      controller.jumpTo(target);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _positionScheduled = false;
        if (!mounted || !_accepting || _ready) return;
        setState(() => _ready = true);
        final indices = _activeTiles.toList()
          ..sort((a, b) => (a - _page).abs().compareTo((b - _page).abs()));
        for (final index in indices) {
          _enqueue(index);
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${_page + 1}/${widget.pageCount}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('comic-page-preview-close'),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: _close,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final innerWidth = constraints.maxWidth - 24;
              final columns = (innerWidth / 120).floor().clamp(2, 6).toInt();
              final tileWidth = (innerWidth - (columns - 1) * 8) / columns;
              final pixelRatio = MediaQuery.devicePixelRatioOf(context);
              final imageWidth = ((tileWidth - 8) * pixelRatio)
                  .round()
                  .clamp(1, 4096)
                  .toInt();
              final imageHeight = (140 * pixelRatio)
                  .round()
                  .clamp(1, 4096)
                  .toInt();
              _positionGrid(columns);
              return GridView.builder(
                controller: widget.scrollController,
                primary: false,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                scrollCacheExtent: const ScrollCacheExtent.pixels(
                  _tileExtent + _tileSpacing,
                ),
                itemCount: widget.pageCount,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisExtent: _tileExtent,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: _tileSpacing,
                ),
                itemBuilder: (context, index) => _ComicPreviewTile(
                  key: ValueKey('comic-page-preview-$index'),
                  pageNumber: index + 1,
                  selected: index == _page,
                  thumbnail: _thumbnail(index),
                  error: _errors[index],
                  onActivate: () => _activate(index, imageWidth, imageHeight),
                  onDeactivate: () => _deactivate(index),
                  onTap: () => _select(index),
                  onRetry: () => _retry(index),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ComicPreviewTile extends StatefulWidget {
  const _ComicPreviewTile({
    super.key,
    required this.pageNumber,
    required this.selected,
    required this.thumbnail,
    required this.error,
    required this.onActivate,
    required this.onDeactivate,
    required this.onTap,
    required this.onRetry,
  });

  final int pageNumber;
  final bool selected;
  final Uint8List? thumbnail;
  final Object? error;
  final VoidCallback onActivate;
  final VoidCallback onDeactivate;
  final VoidCallback onTap;
  final VoidCallback onRetry;

  @override
  State<_ComicPreviewTile> createState() => _ComicPreviewTileState();
}

class _ComicPreviewTileState extends State<_ComicPreviewTile> {
  @override
  void initState() {
    super.initState();
    widget.onActivate();
  }

  @override
  void didUpdateWidget(covariant _ComicPreviewTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageNumber != widget.pageNumber) {
      oldWidget.onDeactivate();
      widget.onActivate();
    }
  }

  @override
  void dispose() {
    widget.onDeactivate();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localizations = S.of(context);
    final loaded = widget.thumbnail != null;
    final thumbnail = widget.thumbnail;
    final onTap = loaded
        ? widget.onTap
        : widget.error != null
        ? widget.onRetry
        : null;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      excludeSemantics: true,
      label:
          '${widget.error != null ? localizations.retry : localizations.preview} ${widget.pageNumber}',
      selected: widget.selected,
      button: onTap != null,
      enabled: onTap != null,
      onTap: onTap,
      child: Material(
        color: scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: widget.selected ? scheme.primary : scheme.outlineVariant,
            width: widget.selected ? 3 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: thumbnail != null
                      ? Image.memory(
                          thumbnail,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        )
                      : widget.error != null
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.broken_image_outlined),
                            Text(localizations.retry),
                          ],
                        )
                      : const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                ),
              ),
              SizedBox(
                height: 30,
                child: Center(
                  child: Text(
                    '${widget.pageNumber}',
                    style: Theme.of(context).textTheme.labelLarge,
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
