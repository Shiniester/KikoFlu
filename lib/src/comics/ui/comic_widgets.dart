import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/work_detail/work_cover_frame.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/app_localizations.dart';
import '../comic_models.dart';

import '../comic_providers.dart';
import 'comic_settings_screen.dart';
import 'comic_detail_screen.dart';

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
  late Future<Uint8List> _image;
  void _load() {
    final source = ref
        .read(comicSourcesProvider)
        .firstWhere((s) => s.key == widget.source);
    _image = ref.read(comicImageLoaderProvider)(source, widget.page);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ComicImage old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source ||
        old.page.url != widget.page.url ||
        old.page.localPath != widget.page.localPath) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _image,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: IconButton(
            tooltip: S.of(context).retry,
            icon: const Icon(Icons.broken_image_outlined),
            onPressed: () => setState(_load),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      return Image.memory(
        snapshot.data!,
        fit: widget.fit,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) =>
            const Center(child: Icon(Icons.broken_image_outlined)),
      );
    },
  );
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
        itemBuilder: (context, i) => ListTile(
          contentPadding: const EdgeInsets.symmetric(
            vertical: 8,
            horizontal: 4,
          ),
          leading: SizedBox(
            width: 54,
            height: 76,
            child: HeroMode(
              enabled: comics.take(i).every((c) => c.key != comics[i].key),
              child: WorkCoverHeroFrame(
                heroTag: comicCoverHeroTag(comics[i]),
                cornerRadius: workCoverCompactRadius,
                child: ComicImage(
                  source: comics[i].source,
                  page: comics[i].coverPage,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          title: Text(
            comics[i].title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(comics[i].source),
          onTap: () => openComic(context, comics[i]),
          onLongPress: onLongPress == null
              ? null
              : () => onLongPress!(comics[i]),
        ),
      );
    }
    return GridView.builder(
      controller: controller,
      padding: padding,
      itemCount: comics.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        childAspectRatio: .58,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
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
            children: [
              Expanded(
                child: HeroMode(
                  enabled: comics.take(i).every((c) => c.key != comics[i].key),
                  child: WorkCoverHeroFrame(
                    heroTag: comicCoverHeroTag(comics[i]),
                    cornerRadius: workCoverCompactRadius,
                    child: ComicImage(
                      source: comics[i].source,
                      page: comics[i].coverPage,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      comics[i].title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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
