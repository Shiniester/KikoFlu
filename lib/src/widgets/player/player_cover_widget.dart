import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../models/audio_track.dart';
import '../../utils/local_file_url.dart';
import '../privacy_blur_cover.dart';

const double playerArtworkAttachmentStart = 0.20;
const double playerArtworkAttachmentEnd = 0.85;
const double playerCoverHeaderFadeStart = 0.55;
const double playerCoverHeaderFadeEnd = 0.85;

double _smoothStep(double value) => value * value * (3 - 2 * value);

@visibleForTesting
double playerArtworkAttachment(double visualProgress) {
  final progress = visualProgress.clamp(0.0, 1.0);
  if (progress <= playerArtworkAttachmentStart) return 0;
  if (progress >= playerArtworkAttachmentEnd) return 1;
  final intervalProgress =
      (progress - playerArtworkAttachmentStart) /
      (playerArtworkAttachmentEnd - playerArtworkAttachmentStart);
  return _smoothStep(intervalProgress);
}

double playerCoverHeaderOpacity(double visualProgress) {
  final progress = visualProgress.clamp(0.0, 1.0);
  if (progress <= playerCoverHeaderFadeStart) return 0;
  if (progress >= playerCoverHeaderFadeEnd) return 1;
  final intervalProgress =
      (progress - playerCoverHeaderFadeStart) /
      (playerCoverHeaderFadeEnd - playerCoverHeaderFadeStart);
  return _smoothStep(intervalProgress);
}

Tween<Rect?> createPlayerArtworkRectTween(
  Rect? begin,
  Rect? end, {
  double viewportHeight = 0,
  bool reverse = false,
}) => _PlayerArtworkRectTween(
  begin: begin,
  end: end,
  viewportHeight: viewportHeight,
  reverse: reverse,
);

class _PlayerArtworkRectTween extends RectTween {
  _PlayerArtworkRectTween({
    required super.begin,
    required super.end,
    required this.viewportHeight,
    required this.reverse,
  });

  final double viewportHeight;
  final bool reverse;

  @override
  Rect? lerp(double t) {
    final source = reverse ? end : begin;
    final target = reverse ? begin : end;
    if (source == null || target == null) return super.lerp(t);
    final visualProgress = reverse ? 1 - t : t;
    final maxTargetShift = math.max(0.0, source.bottom - target.bottom);
    final targetShift = math.min(
      viewportHeight * (1 - visualProgress),
      maxTargetShift,
    );
    final movingTarget = target.shift(Offset(0, targetShift));
    return Rect.lerp(
      source,
      movingTarget,
      playerArtworkAttachment(visualProgress),
    );
  }
}

enum PlayerArtworkFlightTarget { main, none }

Object playerArtworkHeroTag(String trackId, PlayerArtworkFlightTarget target) =>
    'audio_player_artwork_${target.name}_$trackId';

class PlayerArtworkHero extends StatelessWidget {
  const PlayerArtworkHero({
    super.key,
    required this.trackId,
    required this.target,
    required this.cornerRadius,
    required this.child,
    this.enabled = true,
    this.isPlayerPageTarget = false,
    this.flightChild,
  });

  final String trackId;
  final PlayerArtworkFlightTarget target;
  final double cornerRadius;
  final Widget child;
  final bool enabled;
  final bool isPlayerPageTarget;
  final Widget? flightChild;

  @override
  Widget build(BuildContext context) {
    Widget result;
    if (!enabled ||
        target == PlayerArtworkFlightTarget.none ||
        MediaQuery.disableAnimationsOf(context)) {
      result = child;
    } else {
      result = Hero(
        tag: playerArtworkHeroTag(trackId, target),
        createRectTween: (begin, end) => createPlayerArtworkRectTween(
          begin,
          end,
          viewportHeight: MediaQuery.sizeOf(context).height,
          reverse: !isPlayerPageTarget,
        ),
        transitionOnUserGestures: true,
        curve: Curves.linear,
        reverseCurve: Curves.linear,
        flightShuttleBuilder: _playerArtworkFlightShuttle,
        child: _PlayerArtworkHeroPayload(
          cornerRadius: cornerRadius,
          flightChild: flightChild ?? child,
          child: child,
        ),
      );
    }
    return result;
  }
}

class _PlayerArtworkHeroPayload extends StatelessWidget {
  const _PlayerArtworkHeroPayload({
    required this.cornerRadius,
    required this.flightChild,
    required this.child,
  });

  final double cornerRadius;
  final Widget flightChild;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class PlayerCoverPreviewHero extends StatelessWidget {
  const PlayerCoverPreviewHero({
    super.key,
    required this.tag,
    required this.cornerRadius,
    required this.child,
    this.flightChild,
    this.enabled = true,
  });

  final Object tag;
  final double cornerRadius;
  final Widget child;
  final Widget? flightChild;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled || MediaQuery.disableAnimationsOf(context)) return child;
    return Hero(
      tag: tag,
      createRectTween: (begin, end) => RectTween(begin: begin, end: end),
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
      flightShuttleBuilder: _playerCoverPreviewFlightShuttle,
      child: _PlayerCoverPreviewHeroPayload(
        cornerRadius: cornerRadius,
        flightChild: flightChild ?? child,
        child: child,
      ),
    );
  }
}

class _PlayerCoverPreviewHeroPayload extends StatelessWidget {
  const _PlayerCoverPreviewHeroPayload({
    required this.cornerRadius,
    required this.flightChild,
    required this.child,
  });

  final double cornerRadius;
  final Widget flightChild;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

Widget _playerCoverPreviewFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final fromHero = fromHeroContext.widget as Hero;
  final toHero = toHeroContext.widget as Hero;
  final from = fromHero.child as _PlayerCoverPreviewHeroPayload;
  final to = toHero.child as _PlayerCoverPreviewHeroPayload;
  final stableChild = direction == HeroFlightDirection.push
      ? to.flightChild
      : from.flightChild;
  return AnimatedBuilder(
    animation: animation,
    child: stableChild,
    builder: (context, child) {
      final progress = direction == HeroFlightDirection.push
          ? animation.value
          : 1 - animation.value;
      final radius = Tween<double>(
        begin: from.cornerRadius,
        end: to.cornerRadius,
      ).transform(progress);
      return ClipRRect(
        key: const ValueKey('player-cover-preview-flight-frame'),
        borderRadius: BorderRadius.circular(radius),
        child: child,
      );
    },
  );
}

Widget _playerArtworkFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final fromHero = fromHeroContext.widget as Hero;
  final toHero = toHeroContext.widget as Hero;
  final from = fromHero.child as _PlayerArtworkHeroPayload;
  final to = toHero.child as _PlayerArtworkHeroPayload;
  final stableChild = direction == HeroFlightDirection.push
      ? to.flightChild
      : from.flightChild;
  return AnimatedBuilder(
    animation: animation,
    child: stableChild,
    builder: (context, child) {
      final progress = direction == HeroFlightDirection.push
          ? animation.value
          : 1 - animation.value;
      final radius = Tween<double>(
        begin: from.cornerRadius,
        end: to.cornerRadius,
      ).transform(progress);
      return ClipRRect(
        key: const ValueKey('player-artwork-flight-frame'),
        borderRadius: BorderRadius.circular(radius),
        child: child,
      );
    },
  );
}

class PlayerCompactArtwork extends StatelessWidget {
  const PlayerCompactArtwork({
    super.key,
    required this.track,
    required this.url,
    this.forFlight = false,
  });

  static const double height = 48;
  static const double width = height * PlayerCoverWidget.preferredAspectRatio;
  static const double cornerRadius = 10;

  final AudioTrack track;
  final String? url;
  final bool forFlight;

  @override
  Widget build(BuildContext context) {
    final radius = forFlight
        ? BorderRadius.zero
        : BorderRadius.circular(cornerRadius);
    const fallback = Center(child: Icon(Icons.album, size: 30));
    final Widget artwork;
    if (url == null) {
      artwork = fallback;
    } else {
      final image = LocalFileUrl.isLocalFileUrl(url)
          ? Image.file(
              File(LocalFileUrl.pathFromUrl(url!)!),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => fallback,
            )
          : CachedNetworkImage(
              imageUrl: url!,
              cacheKey: track.workId == null
                  ? null
                  : 'work_cover_${track.workId}',
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 220),
              fadeInCurve: Curves.easeOutCubic,
              fadeOutDuration: const Duration(milliseconds: 220),
              fadeOutCurve: Curves.easeOutCubic,
              useOldImageOnUrlChange: true,
              errorWidget: (_, __, ___) => fallback,
              placeholder: (_, __) => fallback,
            );
      artwork = PrivacyBlurCover(
        borderRadius: forFlight ? null : radius,
        child: forFlight
            ? image
            : ClipRRect(borderRadius: radius, child: image),
      );
    }
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: artwork,
      ),
    );
  }
}

/// 播放器封面组件
class PlayerCoverWidget extends StatefulWidget {
  static const double preferredAspectRatio = 4 / 3;
  static const double cornerRadius = 14;

  final AudioTrack track;
  final String? workCoverUrl;
  final bool isLandscape;
  final VoidCallback? onTap;
  final bool heroEnabled;
  final PlayerArtworkFlightTarget heroTarget;
  final Object? previewHeroTag;
  final bool previewHeroEnabled;
  final LayerLink? artworkLayerLink;
  final bool animateTrackChanges;
  @visibleForTesting
  final ImageProvider<Object>? imageProviderOverride;

  const PlayerCoverWidget({
    super.key,
    required this.track,
    this.workCoverUrl,
    this.isLandscape = false,
    this.onTap,
    this.heroEnabled = true,
    this.heroTarget = PlayerArtworkFlightTarget.main,
    this.previewHeroTag,
    this.previewHeroEnabled = false,
    this.artworkLayerLink,
    this.animateTrackChanges = false,
    this.imageProviderOverride,
  });

  @override
  State<PlayerCoverWidget> createState() => _PlayerCoverWidgetState();
}

class _PlayerCoverWidgetState extends State<PlayerCoverWidget>
    with SingleTickerProviderStateMixin {
  static const _transitionDuration = Duration(milliseconds: 300);
  static const _transitionScale = 1.20;

  late final AnimationController _transitionController;
  late _PlayerCoverSnapshot _displayed;
  _PlayerCoverSnapshot? _incoming;
  ImageStream? _pendingImageStream;
  ImageStreamListener? _pendingImageListener;
  int _prepareRevision = 0;
  bool _preparing = false;
  bool _disableAnimations = false;

  bool get _transitionBusy => _preparing || _incoming != null;

  _PlayerCoverSnapshot get _requested => _PlayerCoverSnapshot(
    track: widget.track,
    url: widget.workCoverUrl ?? widget.track.artworkUrl,
    imageProviderOverride: widget.imageProviderOverride,
  );

  @override
  void initState() {
    super.initState();
    _displayed = _requested;
    _transitionController = AnimationController(
      vsync: this,
      duration: _transitionDuration,
    )..addStatusListener(_handleTransitionStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations == disableAnimations) return;
    _disableAnimations = disableAnimations;
    if (disableAnimations && _displayed.identity != _requested.identity) {
      _showImmediately(_requested);
    }
  }

  @override
  void didUpdateWidget(PlayerCoverWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final requested = _requested;
    final previous = _PlayerCoverSnapshot(
      track: oldWidget.track,
      url: oldWidget.workCoverUrl ?? oldWidget.track.artworkUrl,
      imageProviderOverride: oldWidget.imageProviderOverride,
    );
    if (requested.identity != previous.identity &&
        previous.isSameWorkAs(requested)) {
      _showImmediately(requested);
      return;
    }
    if (requested.identity != previous.identity) {
      _prepare(requested);
      return;
    }
    if (!widget.animateTrackChanges && oldWidget.animateTrackChanges) {
      _showImmediately(requested);
    }
  }

  void _prepare(_PlayerCoverSnapshot requested) {
    _cancelPendingImage();
    final revision = ++_prepareRevision;
    if (!widget.animateTrackChanges || _disableAnimations) {
      _showImmediately(requested);
      return;
    }

    final provider = _imageProvider(requested);
    if (provider == null) {
      _beginTransition(requested.copyWith(forcePlaceholder: true));
      return;
    }

    _preparing = true;
    final stream = provider.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, synchronousCall) {
        if (!mounted || revision != _prepareRevision) return;
        _finishPreparing(stream, listener);
        _beginTransition(requested);
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!mounted || revision != _prepareRevision) return;
        _finishPreparing(stream, listener);
        _beginTransition(requested.copyWith(forcePlaceholder: true));
      },
    );
    _pendingImageStream = stream;
    _pendingImageListener = listener;
    stream.addListener(listener);
    if (mounted) setState(() {});
  }

  ImageProvider<Object>? _imageProvider(_PlayerCoverSnapshot snapshot) {
    if (snapshot.forcePlaceholder) return null;
    if (snapshot.imageProviderOverride != null) {
      return snapshot.imageProviderOverride;
    }
    final url = snapshot.url;
    if (url == null) return null;
    if (LocalFileUrl.isLocalFileUrl(url)) {
      final file = File(LocalFileUrl.pathFromUrl(url) ?? url);
      return file.existsSync() ? FileImage(file) : null;
    }
    return CachedNetworkImageProvider(
      url,
      cacheKey: snapshot.track.workId != null
          ? 'work_cover_${snapshot.track.workId}'
          : null,
    );
  }

  void _finishPreparing(ImageStream stream, ImageStreamListener listener) {
    stream.removeListener(listener);
    if (identical(_pendingImageStream, stream)) {
      _pendingImageStream = null;
      _pendingImageListener = null;
    }
    _preparing = false;
  }

  void _beginTransition(_PlayerCoverSnapshot requested) {
    if (!mounted) return;
    if (!widget.animateTrackChanges || _disableAnimations) {
      _showImmediately(requested);
      return;
    }
    setState(() {
      if (_incoming != null && _transitionController.value >= 0.5) {
        _displayed = _incoming!;
      }
      _incoming = requested;
      _preparing = false;
      _transitionController.forward(from: 0);
    });
  }

  void _showImmediately(_PlayerCoverSnapshot requested) {
    _cancelPendingImage();
    _prepareRevision++;
    _transitionController.stop();
    _transitionController.value = 0;
    _displayed = requested;
    _incoming = null;
    _preparing = false;
    if (mounted) setState(() {});
  }

  void _handleTransitionStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _incoming == null) return;
    setState(() {
      _displayed = _incoming!;
      _incoming = null;
      _transitionController.value = 0;
    });
  }

  void _cancelPendingImage() {
    final stream = _pendingImageStream;
    final listener = _pendingImageListener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _pendingImageStream = null;
    _pendingImageListener = null;
    _preparing = false;
  }

  @override
  void dispose() {
    _cancelPendingImage();
    _transitionController
      ..removeStatusListener(_handleTransitionStatus)
      ..dispose();
    super.dispose();
  }

  // 判断是否为本地文件路径
  bool _isLocalFile(String? url) {
    return LocalFileUrl.isLocalFileUrl(url);
  }

  // 从 file:// URL 获取本地文件路径
  String _getLocalPath(String fileUrl) {
    return LocalFileUrl.pathFromUrl(fileUrl) ?? fileUrl;
  }

  Widget _buildArtworkContent(
    _PlayerCoverSnapshot snapshot,
    BorderRadius radius,
  ) {
    if (snapshot.forcePlaceholder) return _buildPlaceholder();
    final provider = snapshot.imageProviderOverride;
    if (provider != null) {
      return PrivacyBlurCover(
        borderRadius: radius,
        child: ClipRRect(
          borderRadius: radius,
          child: Image(
            image: provider,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
          ),
        ),
      );
    }
    if (snapshot.url == null) return _buildPlaceholder();
    final url = snapshot.url!;
    return PrivacyBlurCover(
      borderRadius: radius,
      child: ClipRRect(
        borderRadius: radius,
        child: _isLocalFile(url)
            ? Image.file(
                File(_getLocalPath(url)),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    _buildPlaceholder(),
              )
            : CachedNetworkImage(
                imageUrl: url,
                cacheKey: snapshot.track.workId != null
                    ? 'work_cover_${snapshot.track.workId}'
                    : null,
                fit: BoxFit.cover,
                errorWidget: (context, url, error) => _buildPlaceholder(),
                placeholder: (context, url) => _buildPlaceholder(),
              ),
      ),
    );
  }

  Widget _buildPlaceholder() => Padding(
    padding: const EdgeInsets.all(40),
    child: Icon(Icons.album, size: widget.isLandscape ? 80 : 120),
  );

  Widget _buildTransitionContent(BorderRadius radius) {
    final incoming = _incoming;
    if (incoming == null) {
      return KeyedSubtree(
        key: ValueKey('player-cover-layer-${_displayed.track.id}'),
        child: _buildArtworkContent(_displayed, radius),
      );
    }
    return AnimatedBuilder(
      animation: _transitionController,
      builder: (context, _) {
        final opacity = _transitionController.value;
        final scaleProgress = Curves.easeOutCubic.transform(opacity);
        return Stack(
          key: const ValueKey('player-cover-transition-stack'),
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            Opacity(
              key: const ValueKey('player-cover-outgoing-opacity'),
              opacity: 1 - opacity,
              child: Transform.scale(
                key: const ValueKey('player-cover-outgoing-scale'),
                scale: 1 + (_transitionScale - 1) * scaleProgress,
                child: _buildArtworkContent(_displayed, radius),
              ),
            ),
            Opacity(
              key: const ValueKey('player-cover-incoming-opacity'),
              opacity: opacity,
              child: Transform.scale(
                key: const ValueKey('player-cover-incoming-scale'),
                scale:
                    _transitionScale - (_transitionScale - 1) * scaleProgress,
                child: _buildArtworkContent(incoming, radius),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final transitionBusy = _transitionBusy;
    return GestureDetector(
      onTap: transitionBusy ? null : widget.onTap,
      child: Center(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 360.0;
            final maxHeight = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : 270.0;
            final width = math.min(
              maxWidth,
              maxHeight * PlayerCoverWidget.preferredAspectRatio,
            );
            final height = width / PlayerCoverWidget.preferredAspectRatio;
            final radius = BorderRadius.circular(
              PlayerCoverWidget.cornerRadius,
            );
            final artwork = SizedBox(
              key: ValueKey('player-cover-artwork-${_displayed.track.id}'),
              width: width,
              height: height,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                foregroundDecoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.18),
                  ),
                ),
                // Keep the stable artwork frame's shadow and border outside
                // the clip. Only the image/transition layers are clipped so
                // their fixed 14dp corners remain stable while scaling.
                child: ClipRRect(
                  key: const ValueKey('player-cover-transition-clip'),
                  clipBehavior: Clip.antiAlias,
                  borderRadius: radius,
                  child: _buildTransitionContent(radius),
                ),
              ),
            );
            final previewArtwork = widget.previewHeroTag == null
                ? artwork
                : PlayerCoverPreviewHero(
                    tag: widget.previewHeroTag!,
                    cornerRadius: PlayerCoverWidget.cornerRadius,
                    enabled: widget.previewHeroEnabled && !transitionBusy,
                    child: artwork,
                  );
            final linkedArtwork = widget.artworkLayerLink == null
                ? previewArtwork
                : CompositedTransformTarget(
                    link: widget.artworkLayerLink!,
                    child: previewArtwork,
                  );
            return PlayerArtworkHero(
              trackId: _displayed.track.id,
              target: widget.heroTarget,
              cornerRadius: PlayerCoverWidget.cornerRadius,
              enabled: widget.heroEnabled && !transitionBusy,
              isPlayerPageTarget: true,
              flightChild: PlayerCompactArtwork(
                track: _displayed.track,
                url: _displayed.url,
                forFlight: true,
              ),
              child: linkedArtwork,
            );
          },
        ),
      ),
    );
  }
}

class _PlayerCoverSnapshot {
  const _PlayerCoverSnapshot({
    required this.track,
    required this.url,
    this.forcePlaceholder = false,
    this.imageProviderOverride,
  });

  final AudioTrack track;
  final String? url;
  final bool forcePlaceholder;
  final ImageProvider<Object>? imageProviderOverride;

  bool isSameWorkAs(_PlayerCoverSnapshot other) {
    final currentWorkId = track.workId;
    final otherWorkId = other.track.workId;
    if (currentWorkId != null &&
        otherWorkId != null &&
        currentWorkId == otherWorkId) {
      return true;
    }

    final currentUrl = url;
    final otherUrl = other.url;
    return currentUrl != null &&
        currentUrl.trim().isNotEmpty &&
        otherUrl != null &&
        otherUrl.trim().isNotEmpty &&
        currentUrl == otherUrl;
  }

  String get identity =>
      '${track.id}|${url ?? ''}|${identityHashCode(imageProviderOverride)}';

  _PlayerCoverSnapshot copyWith({bool? forcePlaceholder}) =>
      _PlayerCoverSnapshot(
        track: track,
        url: url,
        forcePlaceholder: forcePlaceholder ?? this.forcePlaceholder,
        imageProviderOverride: imageProviderOverride,
      );
}
