import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/work_detail/work_cover_frame.dart';
import '../../widgets/metadata_search_chip.dart';
import '../../providers/work_card_display_provider.dart';
import '../../providers/works_provider.dart' show LayoutType;
import '../../utils/collection_grid_layout.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../../../l10n/app_localizations.dart';
import '../comic_models.dart';

import '../comic_providers.dart';
import 'comic_settings_screen.dart';
import 'comic_detail_screen.dart';

class _ComicImageRequest {
  const _ComicImageRequest(this.source, this.page);

  final String source;
  final ComicPage page;

  String get key => jsonEncode([source, page.toJson()]);

  @override
  bool operator ==(Object other) =>
      other is _ComicImageRequest && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

class _ComicCoverPicture {
  const _ComicCoverPicture(this.bytes, this.aspectRatio);

  final Uint8List bytes;
  final double aspectRatio;
}

class _ComicCoverRetention {
  final _entries = <_ComicImageRequest, ({int bytes, VoidCallback release})>{};
  int _bytes = 0;

  void touch(_ComicImageRequest request) {
    final entry = _entries.remove(request);
    if (entry != null) _entries[request] = entry;
  }

  void retain(_ComicImageRequest request, int bytes, VoidCallback release) {
    _entries[request] = (bytes: bytes, release: release);
    _bytes += bytes;
    // Keep recent cover bytes stable so Flutter can reuse their decoded frames.
    // Decoded pixels remain governed by Flutter's own bounded ImageCache.
    while (_entries.length > 200 || _bytes > 32 * 1024 * 1024) {
      final oldest = _entries.remove(_entries.keys.first)!;
      _bytes -= oldest.bytes;
      oldest.release();
    }
  }

  void remove(_ComicImageRequest request, VoidCallback release) {
    final entry = _entries[request];
    if (entry?.release != release) return;
    _entries.remove(request);
    _bytes -= entry!.bytes;
  }
}

final _comicCoverRetentionProvider = Provider((ref) => _ComicCoverRetention());

final _comicImageBytesProvider = FutureProvider.autoDispose
    .family<_ComicCoverPicture, _ComicImageRequest>((ref, request) async {
      final retention = ref.read(_comicCoverRetentionProvider);
      var disposed = false;
      ref.onDispose(() => disposed = true);
      final source = ref
          .read(comicSourcesProvider)
          .firstWhere((source) => source.key == request.source);
      final bytes = await ref.read(comicImageLoaderProvider)(
        source,
        request.page,
      );
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          final picture = _ComicCoverPicture(
            bytes,
            descriptor.width / descriptor.height,
          );
          if (!disposed) {
            final release = ref.keepAlive().close;
            retention.retain(request, bytes.lengthInBytes, release);
            ref.onDispose(() => retention.remove(request, release));
          }
          return picture;
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    });

class ComicImage extends StatelessWidget {
  const ComicImage._(
    this.page,
    this._picture,
    this.failed, {
    this.onRetry,
    this.onFirstFrameReady,
  });

  final ComicPage page;
  final _ComicCoverPicture? _picture;
  final bool failed;
  final VoidCallback? onRetry;
  final VoidCallback? onFirstFrameReady;
  BoxFit get fit => BoxFit.contain;

  @override
  Widget build(BuildContext context) {
    final currentPicture = _picture;
    if (currentPicture != null) {
      var notified = false;
      void notifyReady() {
        if (notified || onFirstFrameReady == null) return;
        notified = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onFirstFrameReady!();
        });
      }

      return Image.memory(
        currentPicture.bytes,
        fit: fit,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (frame == 0) notifyReady();
          return child;
        },
        errorBuilder: (context, error, stackTrace) {
          notifyReady();
          return Center(
            child: onRetry == null
                ? const Icon(Icons.broken_image_outlined)
                : IconButton(
                    tooltip: S.of(context).retry,
                    icon: const Icon(Icons.broken_image_outlined),
                    onPressed: onRetry,
                  ),
          );
        },
      );
    }
    if (failed) {
      return Center(
        child: IconButton(
          tooltip: S.of(context).retry,
          icon: const Icon(Icons.broken_image_outlined),
          onPressed: onRetry,
        ),
      );
    }
    return const Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

class ComicCover extends ConsumerStatefulWidget {
  const ComicCover({
    super.key,
    required this.source,
    required this.page,
    required this.heroTag,
    this.maxWidth,
    this.maxHeight,
    this.placeholderAspectRatio,
    this.cornerRadius = workCoverCompactRadius,
    this.onFirstFrameReady,
  });

  final String source;
  final ComicPage page;
  final Object heroTag;
  final double? maxWidth;
  final double? maxHeight;
  final double? placeholderAspectRatio;
  final double cornerRadius;
  final VoidCallback? onFirstFrameReady;

  @override
  ConsumerState<ComicCover> createState() => _ComicCoverState();
}

class _ComicCoverState extends ConsumerState<ComicCover> {
  _ComicCoverPicture? _lastPicture;
  _ComicCoverPicture? _layoutPicture;
  _ComicCoverPicture? _visiblePicture;
  _ComicCoverPicture? _pendingReveal;
  bool _sizeSettled = true;
  bool _animateSize = true;
  bool _visibleFailed = false;
  bool _hasVisibleState = false;
  ModalRoute<dynamic>? _route;

  bool get _routeMoving {
    if (MediaQuery.disableAnimationsOf(context)) return false;
    final primary = _route?.animation?.status;
    final secondary = _route?.secondaryAnimation?.status;
    return primary == AnimationStatus.forward ||
        primary == AnimationStatus.reverse ||
        secondary == AnimationStatus.forward ||
        secondary == AnimationStatus.reverse;
  }

  void _routeStatusChanged(AnimationStatus _) {
    if (mounted && !_routeMoving) {
      setState(() {
        if (_sizeSettled && _pendingReveal != null) {
          _visiblePicture = _pendingReveal;
          _pendingReveal = null;
        }
      });
    }
  }

  void _listenToRoute(ModalRoute<dynamic>? route, {required bool add}) {
    final change = add
        ? (Animation<double>? animation) =>
              animation?.addStatusListener(_routeStatusChanged)
        : (Animation<double>? animation) =>
              animation?.removeStatusListener(_routeStatusChanged);
    change(route?.animation);
    change(route?.secondaryAnimation);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      _listenToRoute(_route, add: false);
      _route = route;
      _listenToRoute(route, add: true);
    }
  }

  @override
  void didUpdateWidget(ComicCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.page.url != widget.page.url) {
      _lastPicture = null;
      _layoutPicture = null;
      _visiblePicture = null;
      _pendingReveal = null;
      _sizeSettled = true;
      _animateSize = true;
      _visibleFailed = false;
      _hasVisibleState = false;
    }
  }

  @override
  void dispose() {
    _listenToRoute(_route, add: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final request = _ComicImageRequest(widget.source, widget.page);
    final image = ref.watch(_comicImageBytesProvider(request));
    if (image.valueOrNull != null) _lastPicture = image.valueOrNull;
    final nextPicture = image.valueOrNull ?? _lastPicture;
    if (!_routeMoving || !_hasVisibleState) {
      final oldRatio =
          _layoutPicture?.aspectRatio ?? widget.placeholderAspectRatio ?? 2 / 3;
      final revealAfterResize =
          widget.onFirstFrameReady == null &&
          _hasVisibleState &&
          _visiblePicture == null &&
          nextPicture != null &&
          !MediaQuery.disableAnimationsOf(context) &&
          (nextPicture.aspectRatio - oldRatio).abs() > 0.001;
      if (revealAfterResize) {
        _animateSize = true;
        _layoutPicture = nextPicture;
        _pendingReveal = nextPicture;
        _sizeSettled = false;
        _visibleFailed = false;
      } else if (_pendingReveal != nextPicture || nextPicture == null) {
        _animateSize =
            _visiblePicture == null ||
            nextPicture == null ||
            (nextPicture.aspectRatio - oldRatio).abs() <= 0.001;
        _layoutPicture = nextPicture;
        _visiblePicture = nextPicture;
        _pendingReveal = null;
        _sizeSettled = true;
        _visibleFailed = image.hasError && nextPicture == null;
      }
      _hasVisibleState = true;
    }
    final picture = _visiblePicture;
    final failed = _visibleFailed;
    final ratio =
        _layoutPicture?.aspectRatio ?? widget.placeholderAspectRatio ?? 2 / 3;
    final content = ComicImage._(
      widget.page,
      picture,
      failed,
      onRetry: () => ref.invalidate(_comicImageBytesProvider(request)),
      onFirstFrameReady: widget.onFirstFrameReady,
    );
    final flightContent = ComicImage._(widget.page, picture, failed);
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = widget.maxWidth ?? constraints.maxWidth;
        final width = math.min(availableWidth, constraints.maxWidth);
        final coverWidth = widget.maxHeight == null
            ? width
            : math.min(width, widget.maxHeight! * ratio);
        final cover = SizedBox(
          width: coverWidth,
          height: coverWidth / ratio,
          child: WorkCoverHeroFrame(
            heroTag: widget.heroTag,
            cornerRadius: widget.cornerRadius,
            flightChild: flightContent,
            child: content,
          ),
        );
        if (MediaQuery.disableAnimationsOf(context) || !_animateSize) {
          return cover;
        }
        return AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topLeft,
          onEnd: () {
            if (mounted && _pendingReveal != null) {
              setState(() {
                _sizeSettled = true;
                if (!_routeMoving) {
                  _visiblePicture = _pendingReveal;
                  _pendingReveal = null;
                }
              });
            }
          },
          child: cover,
        );
      },
    );
  }
}

class ComicErrorView extends StatelessWidget {
  const ComicErrorView({super.key, required this.error, required this.retry});
  final Object error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) {
    final login =
        error is ComicSourceException &&
        (error as ComicSourceException).loginRequired;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              login ? Icons.account_circle_outlined : Icons.error_outline,
              size: 36,
            ),
            const SizedBox(height: 12),
            Text(
              login ? S.of(context).comicLoginRequired : error.toString(),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: retry, child: Text(S.of(context).retry)),
            if (login)
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ComicSettingsScreen(),
                  ),
                ),
                child: Text(S.of(context).comicSettings),
              ),
          ],
        ),
      ),
    );
  }
}

class _ComicCardWhenReady extends ConsumerStatefulWidget {
  const _ComicCardWhenReady({
    required this.source,
    required this.page,
    required this.buildChild,
    this.placeholderAspectRatio,
    this.onAspectRatio,
  });

  final String source;
  final ComicPage page;
  final Widget Function(VoidCallback onFirstFrameReady) buildChild;
  final double? placeholderAspectRatio;
  final ValueChanged<double>? onAspectRatio;

  @override
  ConsumerState<_ComicCardWhenReady> createState() =>
      _ComicCardWhenReadyState();
}

class _ComicCardWhenReadyState extends ConsumerState<_ComicCardWhenReady> {
  bool _shown = false;
  int _generation = 0;

  @override
  void didUpdateWidget(_ComicCardWhenReady oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.page.url != widget.page.url) {
      _shown = false;
      _generation++;
    }
  }

  void _showWhenReady(int generation) {
    if (!mounted || generation != _generation || _shown) return;
    setState(() => _shown = true);
  }

  @override
  Widget build(BuildContext context) {
    final request = _ComicImageRequest(widget.source, widget.page);
    final image = ref.watch(_comicImageBytesProvider(request));
    ref.read(_comicCoverRetentionProvider).touch(request);
    final picture = image.valueOrNull;
    if (picture != null) {
      widget.onAspectRatio?.call(picture.aspectRatio);
      if (PaintingBinding.instance.imageCache
          .statusForKey(MemoryImage(picture.bytes))
          .keepAlive) {
        _shown = true;
      }
    }
    if (image.hasError) {
      widget.onAspectRatio?.call(widget.placeholderAspectRatio ?? 2 / 3);
      _shown = true;
    }
    final generation = _generation;
    return Visibility(
      visible: _shown,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: widget.buildChild(() => _showWhenReady(generation)),
    );
  }
}

class ComicGrid extends ConsumerStatefulWidget {
  const ComicGrid({
    super.key,
    required this.comics,
    this.padding,
    this.controller,
    this.onLongPress,
    this.emptyContent,
    this.footer,
  });
  final List<Comic> comics;
  final EdgeInsets? padding;
  final ScrollController? controller;
  final void Function(Comic)? onLongPress;
  final Widget? emptyContent;
  final Widget? footer;

  @override
  ConsumerState<ComicGrid> createState() => _ComicGridState();
}

class _ComicGridState extends ConsumerState<ComicGrid> {
  final _coverAspectRatios = <String, double>{};

  Widget _readyCard(
    Comic comic,
    Widget Function(double?, VoidCallback) buildCard,
  ) {
    final page = comic.coverPage;
    final request = _ComicImageRequest(comic.source, page);
    final placeholderAspectRatio = _coverAspectRatios[request.key];
    return _ComicCardWhenReady(
      source: comic.source,
      page: page,
      placeholderAspectRatio: placeholderAspectRatio,
      onAspectRatio: (ratio) => _coverAspectRatios[request.key] = ratio,
      buildChild: (onFirstFrameReady) =>
          buildCard(placeholderAspectRatio, onFirstFrameReady),
    );
  }

  @override
  Widget build(BuildContext context) {
    final comics = widget.comics;
    final padding = widget.padding;
    final controller = widget.controller;
    final onLongPress = widget.onLongPress;
    final layoutType = ref.watch(comicLayoutProvider);
    final isList = layoutType == LayoutType.list;
    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = resolveCollectionGridMetrics(
          context,
          layoutType: layoutType,
          cardSize: WorkCardSize.normal,
          padding: padding,
          availableWidth: constraints.hasBoundedWidth
              ? constraints.maxWidth
              : null,
          availableHeight: constraints.hasBoundedHeight
              ? constraints.maxHeight
              : null,
        );
        final detailMetrics = isList
            ? resolveCollectionGridMetrics(
                context,
                layoutType: LayoutType.bigGrid,
                cardSize: WorkCardSize.normal,
                padding: padding,
                availableWidth: constraints.hasBoundedWidth
                    ? constraints.maxWidth
                    : null,
                availableHeight: constraints.hasBoundedHeight
                    ? constraints.maxHeight
                    : null,
              )
            : metrics;
        final contentWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final gridCoverWidth =
            (contentWidth -
                detailMetrics.padding.horizontal -
                detailMetrics.spacing * (detailMetrics.crossAxisCount - 1)) /
            detailMetrics.crossAxisCount;
        if (comics.isEmpty) {
          return CustomScrollView(
            controller: controller,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child:
                    widget.emptyContent ??
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(child: Text(S.of(context).comicNoResults)),
                    ),
              ),
              if (widget.footer != null)
                SliverToBoxAdapter(child: widget.footer!),
            ],
          );
        }
        final isLandscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        if (isList) {
          return CustomScrollView(
            controller: controller,
            slivers: [
              SliverPadding(
                padding: metrics.padding,
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _readyCard(
                      comics[i],
                      (placeholderAspectRatio, onFirstFrameReady) => Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        clipBehavior: Clip.antiAlias,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            workCoverCompactRadius,
                          ),
                        ),
                        child: InkWell(
                          onTap: () => openComic(
                            context,
                            comics[i],
                            gridCoverWidth: gridCoverWidth,
                          ),
                          onLongPress: onLongPress == null
                              ? null
                              : () => onLongPress(comics[i]),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                HeroMode(
                                  enabled: comics
                                      .take(i)
                                      .every((c) => c.key != comics[i].key),
                                  child: ComicCover(
                                    source: comics[i].source,
                                    page: comics[i].coverPage,
                                    heroTag: comicCoverHeroTag(comics[i]),
                                    maxWidth: 80,
                                    placeholderAspectRatio:
                                        placeholderAspectRatio,
                                    onFirstFrameReady: onFirstFrameReady,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        comics[i].title,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.bold,
                                              height: 1.3,
                                              fontSize: isLandscape ? 16 : 14,
                                            ),
                                      ),
                                      if (comics[i].tags.isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        Wrap(
                                          spacing: 3,
                                          runSpacing: 2,
                                          children: comics[i].tags
                                              .map(
                                                (tag) => IgnorePointer(
                                                  child: MetadataSearchChip(
                                                    label: tag,
                                                    searchKeyword: tag,
                                                    searchTypeLabel: S
                                                        .of(context)
                                                        .searchTypeTag,
                                                    searchParams: const {},
                                                    chipTone: MetadataChipTone
                                                        .secondary,
                                                    customTone: MetadataChipTone
                                                        .primary,
                                                    fontSize: isLandscape
                                                        ? 13
                                                        : 11,
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 4,
                                                          vertical: 1,
                                                        ),
                                                    borderRadius: 6,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              )
                                              .toList(),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    childCount: comics.length,
                  ),
                ),
              ),
              if (widget.footer != null)
                SliverToBoxAdapter(child: widget.footer!),
            ],
          );
        }
        return CustomScrollView(
          controller: controller,
          slivers: [
            SliverPadding(
              padding: metrics.padding,
              sliver: SliverMasonryGrid.count(
                crossAxisCount: metrics.crossAxisCount,
                childCount: comics.length,
                crossAxisSpacing: metrics.spacing,
                mainAxisSpacing: metrics.spacing,
                itemBuilder: (context, i) => _readyCard(
                  comics[i],
                  (placeholderAspectRatio, onFirstFrameReady) => Card(
                    clipBehavior: Clip.antiAlias,
                    margin: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        workCoverCompactRadius,
                      ),
                    ),
                    child: InkWell(
                      onTap: () => openComic(
                        context,
                        comics[i],
                        gridCoverWidth: gridCoverWidth,
                      ),
                      onLongPress: onLongPress == null
                          ? null
                          : () => onLongPress(comics[i]),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Stack(
                            children: [
                              HeroMode(
                                enabled: comics
                                    .take(i)
                                    .every((c) => c.key != comics[i].key),
                                child: ComicCover(
                                  source: comics[i].source,
                                  page: comics[i].coverPage,
                                  heroTag: comicCoverHeroTag(comics[i]),
                                  placeholderAspectRatio:
                                      placeholderAspectRatio,
                                  onFirstFrameReady: onFirstFrameReady,
                                ),
                              ),
                              if (comics[i].coverDate case final date?)
                                Positioned(
                                  right: 6,
                                  bottom: 6,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.7,
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      date,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: isLandscape ? 13 : 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  comics[i].title,
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        height: 1.1,
                                        fontSize:
                                            layoutType == LayoutType.smallGrid
                                            ? (isLandscape ? 13.5 : 11)
                                            : isLandscape
                                            ? 14.5
                                            : 12,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (widget.footer != null)
              SliverToBoxAdapter(child: widget.footer!),
          ],
        );
      },
    );
  }
}

String comicCoverHeroTag(Comic comic) => 'comic-cover:${comic.key}';

void openComic(BuildContext context, Comic comic, {double? gridCoverWidth}) {
  final windowWidth = gridCoverWidth == null
      ? null
      : MediaQuery.sizeOf(context).width;
  pushWorkDetailRoute(
    context,
    builder: (_) => ComicDetailScreen(
      comic: comic,
      initialGridCoverWidth: gridCoverWidth,
      initialWindowWidth: windowWidth,
    ),
  );
}

class ComicKeepAlive extends StatefulWidget {
  const ComicKeepAlive({super.key, required this.child});
  final Widget child;
  @override
  State<ComicKeepAlive> createState() => _ComicKeepAliveState();
}

class _ComicKeepAliveState extends State<ComicKeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
