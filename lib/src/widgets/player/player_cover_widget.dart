import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../models/audio_track.dart';
import '../../utils/local_file_url.dart';
import '../privacy_blur_cover.dart';

Tween<Rect?> createPlayerArtworkRectTween(Rect? begin, Rect? end) =>
    RectTween(begin: begin, end: end);

/// 播放器封面组件
class PlayerCoverWidget extends StatelessWidget {
  static const double preferredAspectRatio = 4 / 3;
  static const double cornerRadius = 14;

  final AudioTrack track;
  final String? workCoverUrl;
  final bool isLandscape;
  final VoidCallback? onTap;

  const PlayerCoverWidget({
    super.key,
    required this.track,
    this.workCoverUrl,
    this.isLandscape = false,
    this.onTap,
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
            if (MediaQuery.disableAnimationsOf(context)) return artwork;
            return Hero(
              tag: 'audio_player_artwork_${track.id}',
              createRectTween: createPlayerArtworkRectTween,
              transitionOnUserGestures: true,
              child: artwork,
            );
          },
        ),
      ),
    );
  }
}
