import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/work_detail/work_cover_frame.dart';
import 'dart:typed_data';
import 'dart:convert';
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

final _comicImageBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, _ComicImageRequest>((ref, request) {
      final source = ref
          .read(comicSourcesProvider)
          .firstWhere((source) => source.key == request.source);
      return ref.read(comicImageLoaderProvider)(source, request.page);
    });

class ComicImage extends ConsumerStatefulWidget {
  const ComicImage({
    super.key,
    required this.source,
    required this.page,
    this.fit = BoxFit.contain,
  });
  final String source;
  final ComicPage page;
  final BoxFit fit;

  @override
  ConsumerState<ComicImage> createState() => _ComicImageState();
}

class _ComicImageState extends ConsumerState<ComicImage> {
  Uint8List? _lastBytes;

  @override
  void didUpdateWidget(ComicImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.page.url != widget.page.url) {
      _lastBytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = _ComicImageRequest(widget.source, widget.page);
    final image = ref.watch(_comicImageBytesProvider(request));
    final bytes = image.valueOrNull ?? _lastBytes;
    if (image.valueOrNull != null) _lastBytes = image.valueOrNull;
    if (image.hasError) {
      return Center(
        child: IconButton(
          tooltip: S.of(context).retry,
          icon: const Icon(Icons.broken_image_outlined),
          onPressed: () => ref.invalidate(_comicImageBytesProvider(request)),
        ),
      );
    }
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: widget.fit,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) =>
            const Center(child: Icon(Icons.broken_image_outlined)),
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

class ComicGrid extends ConsumerWidget {
  const ComicGrid({
    super.key,
    required this.comics,
    this.padding = const EdgeInsets.all(16),
    this.controller,
    this.onLongPress,
  });
  final List<Comic> comics;
  final EdgeInsets padding;
  final ScrollController? controller;
  final void Function(Comic)? onLongPress;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (comics.isEmpty) {
      return ListView(
        controller: controller,
        padding: padding,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(child: Text(S.of(context).comicNoResults)),
          ),
        ],
      );
    }
    final grid = ref.watch(comicGridProvider);
    if (!grid) {
      return ListView.builder(
        controller: controller,
        padding: padding,
        itemCount: comics.length,
        itemBuilder: (context, i) => Card(
          margin: const EdgeInsets.symmetric(vertical: 6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => openComic(context, comics[i]),
            onLongPress: onLongPress == null
                ? null
                : () => onLongPress!(comics[i]),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 80,
                    height: 120,
                    child: HeroMode(
                      enabled: comics
                          .take(i)
                          .every((c) => c.key != comics[i].key),
                      child: WorkCoverHeroFrame(
                        heroTag: comicCoverHeroTag(comics[i]),
                        cornerRadius: workCoverCompactRadius,
                        child: ComicImage(
                          source: comics[i].source,
                          page: comics[i].coverPage,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          comics[i].title,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          comics[i].source,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return MasonryGridView.builder(
      controller: controller,
      padding: padding,
      itemCount: comics.length,
      gridDelegate: const SliverSimpleGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
      ),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      itemBuilder: (context, i) => Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: () => openComic(context, comics[i]),
          onLongPress: onLongPress == null
              ? null
              : () => onLongPress!(comics[i]),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 2 / 3,
                child: HeroMode(
                  enabled: comics.take(i).every((c) => c.key != comics[i].key),
                  child: WorkCoverHeroFrame(
                    heroTag: comicCoverHeroTag(comics[i]),
                    cornerRadius: workCoverCompactRadius,
                    child: ComicImage(
                      source: comics[i].source,
                      page: comics[i].coverPage,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      comics[i].title,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    Text(
                      comics[i].source,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String comicCoverHeroTag(Comic comic) => 'comic-cover:${comic.key}';

void openComic(BuildContext context, Comic comic) {
  pushWorkDetailRoute(context, builder: (_) => ComicDetailScreen(comic: comic));
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
