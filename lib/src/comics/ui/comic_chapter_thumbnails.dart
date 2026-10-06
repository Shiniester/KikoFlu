import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../comic_models.dart';
import '../comic_providers.dart';
import 'comic_widgets.dart';

List<int> comicChapterThumbnailIndices(int pageCount) => pageCount <= 0
    ? const []
    : {0, (pageCount - 1) ~/ 2, pageCount - 1}.toList();

class ComicChapterThumbnails extends ConsumerStatefulWidget {
  const ComicChapterThumbnails({
    super.key,
    required this.comic,
    required this.chapter,
    required this.onSelected,
  });

  final Comic comic;
  final ComicChapter chapter;
  final ValueChanged<int> onSelected;

  @override
  ConsumerState<ComicChapterThumbnails> createState() =>
      _ComicChapterThumbnailsState();
}

class _ComicChapterThumbnailsState
    extends ConsumerState<ComicChapterThumbnails> {
  late Future<List<ComicPage>> _pages = _loadPages();

  Future<List<ComicPage>> _loadPages() async {
    final offline = await ref
        .read(comicDownloadsProvider)
        .offlinePages(widget.comic, widget.chapter);
    if (offline != null) return offline;
    if (!mounted) return const [];
    final source = ref
        .read(comicSourcesProvider)
        .firstWhere((source) => source.key == widget.comic.source);
    return source.pages(widget.comic, widget.chapter);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<ComicPage>>(
    future: _pages,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return SizedBox(
          height: 148,
          child: Center(
            child: TextButton.icon(
              onPressed: () => setState(() {
                _pages = _loadPages();
              }),
              icon: const Icon(Icons.refresh),
              label: Text(S.of(context).retry),
            ),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const SizedBox(
          height: 148,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      final pages = snapshot.data!;
      final indices = comicChapterThumbnailIndices(pages.length);
      if (indices.isEmpty) return const SizedBox.shrink();
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = math.min(
            96.0,
            (constraints.maxWidth - 8 * (indices.length - 1)) / indices.length,
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < indices.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                SizedBox(
                  width: width,
                  child: InkWell(
                    key: ValueKey(
                      'comic-chapter-thumbnail-${widget.chapter.id}-${indices[i]}',
                    ),
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => widget.onSelected(indices[i]),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 120,
                          child: Center(
                            child: ComicCover(
                              source: widget.comic.source,
                              page: pages[indices[i]],
                              maxWidth: width,
                              maxHeight: 120,
                              cornerRadius: 6,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(S.of(context).comicPreviewPage(indices[i] + 1)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      );
    },
  );
}
