import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../models/audio_track.dart';
import '../../utils/local_file_url.dart';
import '../privacy_blur_cover.dart';
import 'player_vertical_gestures.dart';

Tween<Rect?> createPlayerArtworkRectTween(Rect? begin, Rect? end) =>
    RectTween(begin: begin, end: end);

enum PlayerArtworkFlightTarget { main, queue, none }

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
    this.flightChild,
    this.keepPlaceholderVisible = false,
  });

  final String trackId;
  final PlayerArtworkFlightTarget target;
  final double cornerRadius;
  final Widget child;
  final bool enabled;
  final Widget? flightChild;
  final bool keepPlaceholderVisible;

  @override
  Widget build(BuildContext context) {
    if (!enabled ||
        target == PlayerArtworkFlightTarget.none ||
        MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    final modalRoute = ModalRoute.of(context);
    final PlayerArtworkMotionRoute? motionRoute =
        modalRoute is PlayerArtworkMotionRoute
        ? modalRoute as PlayerArtworkMotionRoute
        : null;
    return Hero(
      tag: playerArtworkHeroTag(trackId, target),
      createRectTween: createPlayerArtworkRectTween,
      transitionOnUserGestures: true,
      curve: _PlayerArtworkRouteCurve(
        motionRoute: motionRoute,
        settledCurve: Curves.easeOutCubic,
      ),
      reverseCurve: _PlayerArtworkRouteCurve(
        motionRoute: motionRoute,
        settledCurve: Curves.easeInCubic,
      ),
      flightShuttleBuilder: _playerArtworkFlightShuttle,
      placeholderBuilder: keepPlaceholderVisible
          ? (context, size, heroChild) =>
                SizedBox.fromSize(size: size, child: heroChild)
          : null,
      child: _PlayerArtworkHeroPayload(
        cornerRadius: cornerRadius,
        flightChild: flightChild ?? child,
        motionRoute: motionRoute,
        child: child,
      ),
    );
  }
}

class _PlayerArtworkRouteCurve extends Curve {
  const _PlayerArtworkRouteCurve({
    required this.motionRoute,
    required this.settledCurve,
  });

  final PlayerArtworkMotionRoute? motionRoute;
  final Curve settledCurve;

  @override
  double transformInternal(double t) {
    if (motionRoute?.playerArtworkUsesRawProgress == true) return t;
    return settledCurve.transform(t);
  }
}

class _PlayerArtworkHeroPayload extends StatelessWidget {
  const _PlayerArtworkHeroPayload({
    required this.cornerRadius,
    required this.flightChild,
    required this.motionRoute,
    required this.child,
  });

  final double cornerRadius;
  final Widget flightChild;
  final PlayerArtworkMotionRoute? motionRoute;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
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
  final stableChild = from.flightChild;
  final motionRoute = direction == HeroFlightDirection.push
      ? to.motionRoute
      : from.motionRoute;
  final viewportHeight = MediaQuery.sizeOf(flightContext).height;
  final initialRouteTop = motionRoute == null
      ? 0.0
      : (1 - motionRoute.playerVisualProgress) * viewportHeight;
  final fromRect = _playerArtworkGlobalRect(
    fromHeroContext,
  )?.translate(0, from.motionRoute == null ? 0 : -initialRouteTop);
  final toRect = _playerArtworkGlobalRect(
    toHeroContext,
  )?.translate(0, to.motionRoute == null ? 0 : -initialRouteTop);
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
      final currentRect = fromRect == null || toRect == null
          ? null
          : Rect.lerp(fromRect, toRect, progress);
      final routeTop = motionRoute == null
          ? 0.0
          : (1 - motionRoute.playerVisualProgress) * viewportHeight;
      final clipTop = currentRect == null
          ? 0.0
          : (routeTop - currentRect.top).clamp(0.0, currentRect.height);
      return ClipRect(
        clipper: _PlayerArtworkViewportClipper(clipTop),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: child,
        ),
      );
    },
  );
}

Rect? _playerArtworkGlobalRect(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox ||
      !renderObject.attached ||
      !renderObject.hasSize) {
    return null;
  }
  return renderObject.localToGlobal(Offset.zero) & renderObject.size;
}

class _PlayerArtworkViewportClipper extends CustomClipper<Rect> {
  const _PlayerArtworkViewportClipper(this.top);

  final double top;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, top.clamp(0.0, size.height), size.width, size.height);

  @override
  bool shouldReclip(_PlayerArtworkViewportClipper oldClipper) =>
      oldClipper.top != top;
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
    final radius = BorderRadius.circular(forFlight ? 0 : cornerRadius);
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
              fadeInDuration: forFlight
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              fadeInCurve: Curves.easeOutCubic,
              fadeOutDuration: forFlight
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
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
class PlayerCoverWidget extends StatelessWidget {
  static const double preferredAspectRatio = 4 / 3;
  static const double cornerRadius = 14;

  final AudioTrack track;
  final String? workCoverUrl;
  final bool isLandscape;
  final VoidCallback? onTap;
  final bool heroEnabled;
  final PlayerArtworkFlightTarget heroTarget;

  const PlayerCoverWidget({
    super.key,
    required this.track,
    this.workCoverUrl,
    this.isLandscape = false,
    this.onTap,
    this.heroEnabled = true,
    this.heroTarget = PlayerArtworkFlightTarget.main,
  });

  // 判断是否为本地文件路径
  bool _isLocalFile(String? url) {
    return LocalFileUrl.isLocalFileUrl(url);
  }

  // 从 file:// URL 获取本地文件路径
  String _getLocalPath(String fileUrl) {
    return LocalFileUrl.pathFromUrl(fileUrl) ?? fileUrl;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Center(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 360.0;
            final maxHeight = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : 270.0;
            final width = math.min(maxWidth, maxHeight * preferredAspectRatio);
            final height = width / preferredAspectRatio;
            final radius = BorderRadius.circular(cornerRadius);
            final artwork = SizedBox(
              key: ValueKey('player-cover-artwork-${track.id}'),
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
                child: (workCoverUrl ?? track.artworkUrl) != null
                    ? PrivacyBlurCover(
                        borderRadius: radius,
                        child: ClipRRect(
                          borderRadius: radius,
                          child: _isLocalFile(workCoverUrl ?? track.artworkUrl)
                              ? Image.file(
                                  File(
                                    _getLocalPath(
                                      (workCoverUrl ?? track.artworkUrl)!,
                                    ),
                                  ),
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return Padding(
                                      padding: const EdgeInsets.all(40),
                                      child: Icon(
                                        Icons.album,
                                        size: isLandscape ? 80 : 120,
                                      ),
                                    );
                                  },
                                )
                              : CachedNetworkImage(
                                  imageUrl: (workCoverUrl ?? track.artworkUrl)!,
                                  // 使用workId作为cacheKey，与作品详情页保持一致，避免token变化导致重新下载
                                  cacheKey: track.workId != null
                                      ? 'work_cover_${track.workId}'
                                      : null,
                                  fit: BoxFit.cover,
                                  errorWidget: (context, url, error) {
                                    return Padding(
                                      padding: const EdgeInsets.all(40),
                                      child: Icon(
                                        Icons.album,
                                        size: isLandscape ? 80 : 120,
                                      ),
                                    );
                                  },
                                  placeholder: (context, url) {
                                    return Padding(
                                      padding: const EdgeInsets.all(40),
                                      child: Icon(
                                        Icons.album,
                                        size: isLandscape ? 80 : 120,
                                      ),
                                    );
                                  },
                                ),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(40),
                        child: Icon(Icons.album, size: isLandscape ? 80 : 120),
                      ),
              ),
            );
            return PlayerArtworkHero(
              trackId: track.id,
              target: heroTarget,
              cornerRadius: cornerRadius,
              enabled: heroEnabled,
              flightChild: PlayerCompactArtwork(
                track: track,
                url: workCoverUrl ?? track.artworkUrl,
                forFlight: true,
              ),
              child: artwork,
            );
          },
        ),
      ),
    );
  }
}
