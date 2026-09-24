import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../models/playlist.dart';
import '../providers/auth_provider.dart';
import '../providers/works_provider.dart' show LayoutType;
import '../services/storage_service.dart';
import '../utils/collection_grid_layout.dart';
import 'privacy_blur_cover.dart';

class PlaylistCard extends ConsumerWidget {
  const PlaylistCard({
    super.key,
    required this.playlist,
    this.onTap,
    this.onDelete,
    this.layoutType = LayoutType.list,
  });

  final Playlist playlist;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final LayoutType layoutType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(
      authProvider.select(
        (value) => (host: value.host ?? '', token: value.token ?? ''),
      ),
    );
    final theme = Theme.of(context);
    final isList = layoutType == LayoutType.list;

    return LayoutBuilder(
      builder: (context, constraints) {
        final coverWidth = isList
            ? collectionListCoverSize.width
            : constraints.maxWidth;
        final radius = collectionCoverRadius(coverWidth);
        final cover = ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: PrivacyBlurCover(
            borderRadius: BorderRadius.circular(radius),
            child: CachedNetworkImage(
              imageUrl: playlist.getFullCoverUrl(auth.host, token: auth.token),
              httpHeaders: StorageService.serverCookieHeaders,
              cacheKey: 'playlist_cover_${playlist.id}|${playlist.updatedAt}',
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              placeholder: (context, url) => Container(
                color: theme.colorScheme.surfaceContainerHighest,
                child: const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              errorWidget: (context, url, error) => Container(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.playlist_play,
                  size: 32,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        );
        final info = _buildInfo(context, theme, onDelete != null);

        return Card(
          elevation: 1,
          margin: isList
              ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
              : EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(isList ? 8 : radius),
          ),
          child: InkWell(
            onTap: onTap,
            child: isList
                ? ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 76),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: collectionListCoverSize.width,
                          height: collectionListCoverSize.height,
                          child: cover,
                        ),
                        Expanded(child: info),
                      ],
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AspectRatio(
                        aspectRatio: collectionCoverAspectRatio,
                        child: cover,
                      ),
                      info,
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _buildInfo(BuildContext context, ThemeData theme, bool canDelete) {
    final authorAndCount = LayoutBuilder(
      builder: (context, constraints) {
        final personIcon = Icon(
          Icons.person_outline,
          size: 12,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        );
        final audioIcon = Icon(
          Icons.audiotrack,
          size: 12,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        );
        final userName = Text(
          playlist.userName,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
            fontSize: 11,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
        final workCount = Text(
          '${playlist.worksCount}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
            fontSize: 11,
          ),
        );

        if (constraints.maxWidth < 100) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  personIcon,
                  const SizedBox(width: 3),
                  Expanded(child: userName),
                ],
              ),
              Row(children: [audioIcon, const SizedBox(width: 3), workCount]),
            ],
          );
        }

        return Row(
          children: [
            personIcon,
            const SizedBox(width: 3),
            Flexible(child: userName),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '•',
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.5,
                  ),
                  fontSize: 11,
                ),
              ),
            ),
            audioIcon,
            const SizedBox(width: 3),
            workCount,
          ],
        );
      },
    );
    final description = playlist.description.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              playlist.description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.6,
                ),
                fontSize: 11,
                height: 1.3,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  playlist.displayName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (canDelete)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: theme.colorScheme.error.withValues(alpha: 0.7),
                  ),
                  onPressed: onDelete,
                  tooltip: S.of(context).delete,
                )
              else
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.4,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          authorAndCount,
          description,
        ],
      ),
    );
  }
}
