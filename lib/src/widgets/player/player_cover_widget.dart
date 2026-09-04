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
    final movingTarget = target.shift(
      Offset(0, viewportHeight * (1 - visualProgress)),
    );
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
  });

  final String trackId;
  final PlayerArtworkFlightTarget target;
  final double cornerRadius;
  final Widget child;
  final bool enabled;
  final bool isPlayerPageTarget;

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
    required this.child,
  });

  final double cornerRadius;
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
  final stableChild = direction == HeroFlightDirection.push
      ? to.child
      : from.child;
  return AnimatedBuilder(
    animation: animation,
    child: stableChild,
    builder: (context, child) {
      final radius = Tween<double>(
        begin: from.cornerRadius,
        end: to.cornerRadius,
      ).evaluate(animation);
      return ClipRRect(
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
  });

  static const double height = 48;
  static const double width = height * PlayerCoverWidget.preferredAspectRatio;
  static const double cornerRadius = 10;

  final AudioTrack track;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(cornerRadius);
    const fallback = Center(child: Icon(Icons.album, size: 30));
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: url == null
            ? fallback
            : PrivacyBlurCover(
                borderRadius: radius,
                child: ClipRRect(
                  borderRadius: radius,
                  child: LocalFileUrl.isLocalFileUrl(url)
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
                        ),
                ),
              ),
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
              isPlayerPageTarget: true,
              child: artwork,
            );
          },
        ),
      ),
    );
  }
}
