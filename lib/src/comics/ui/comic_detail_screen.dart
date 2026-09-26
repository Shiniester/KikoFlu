import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/app_localizations.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../../widgets/scrollable_appbar.dart';
import '../../widgets/metadata_search_chip.dart';
import '../../widgets/work_detail/work_cover_frame.dart';
import '../../widgets/work_detail/work_title_header.dart';
import '../../utils/system_ui_style.dart';
import '../../services/log_service.dart';
import 'comic_search_screen.dart';
import '../../utils/snackbar_util.dart';
import '../comic_models.dart';
import '../comic_providers.dart';
import 'comic_widgets.dart';
import 'comic_reader_screen.dart';

class ComicDetailScreen extends ConsumerStatefulWidget {
  const ComicDetailScreen({super.key, required this.comic});
  final Comic comic;
  @override
  ConsumerState<ComicDetailScreen> createState() => _ComicDetailScreenState();
}

class _ComicDetailScreenState extends ConsumerState<ComicDetailScreen> {
  late Comic _comic = widget.comic;
  late List<ComicChapter> _chapters = widget.comic.chapters;
  final Stopwatch _loadTime = Stopwatch()..start();
  bool _metadataLoading = true;
  bool _chaptersLoading = true;
  Object? _metadataError;
  Object? _chaptersError;
  bool _busy = false;
  Object? _favoriteError;
  Comic get _readyComic => _comic.withChapters(_chapters);

  Future<void> _load() async {
    final downloads = ref.read(comicDownloadsProvider);
    await downloads.ready;
    if (!mounted) return;
    final saved = downloads.completedComics
        .where((c) => c.key == widget.comic.key)
        .firstOrNull;
    if (saved != null) {
      setState(() {
        _comic = saved;
        _chapters = saved.chapters;
        _metadataLoading = false;
        _chaptersLoading = false;
      });
      _logTiming('metadata complete');
      _logTiming('chapters complete');
      return;
    }
    await _loadMetadata();
  }

  void _logTiming(String stage) => LogService.instance.info(
    'Detail $stage ${_loadTime.elapsedMilliseconds}ms (${widget.comic.source})',
    tag: 'Comics',
  );

  Future<void> _loadMetadata() async {
    setState(() {
      _metadataLoading = true;
      _metadataError = null;
    });
    try {
      final comic = await ref
          .read(comicSourcesProvider)
          .firstWhere((s) => s.key == widget.comic.source)
          .details(widget.comic.id);
      if (!mounted) return;
      setState(() => _comic = comic);
    } catch (error) {
      if (!mounted) return;
      setState(() => _metadataError = error);
    } finally {
      if (mounted) {
        setState(() => _metadataLoading = false);
        _logTiming(
          _metadataError == null ? 'metadata complete' : 'metadata failed',
        );
        if (_chaptersLoading) _loadChapters();
      }
    }
  }

  Future<void> _loadChapters() async {
    setState(() {
      _chaptersLoading = true;
      _chaptersError = null;
    });
    try {
      final chapters = await ref
          .read(comicSourcesProvider)
          .firstWhere((s) => s.key == widget.comic.source)
          .chapters(_comic);
      if (mounted) setState(() => _chapters = chapters);
    } catch (error) {
      if (mounted) setState(() => _chaptersError = error);
    } finally {
      if (mounted) {
        setState(() => _chaptersLoading = false);
        _logTiming(
          _chaptersError == null ? 'chapters complete' : 'chapters failed',
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _logTiming('first visible');
    });
  }

  Future<void> _read(Comic comic, {ComicChapter? chapter}) async {
    if (comic.chapters.isEmpty) return;
    final progress = await ref.read(comicLibraryProvider).progress(comic);
    chapter ??=
        comic.chapters.where((c) => c.id == progress?.chapterId).firstOrNull ??
        comic.chapters.first;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ComicReaderScreen(
          comic: comic,
          chapter: chapter!,
          initialPage: progress?.chapterId == chapter.id ? progress!.page : 0,
        ),
      ),
    );
  }

  Future<void> _favorite(Comic comic) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _favoriteError = null;
    });
    try {
      final source = ref
          .read(comicSourcesProvider)
          .firstWhere((s) => s.key == comic.source);
      if (source.hasRemoteFavorites && source.isLoggedIn) {
        await source.setFavorite(comic, true);
        if (mounted) {
          ref.read(comicRemoteFavoritesRevisionProvider.notifier).state++;
        }
      }
      await ref.read(comicLibraryProvider).favorite(comic, true);
      if (mounted) SnackBarUtil.showSuccess(context, S.of(context).comicSaved);
    } catch (e) {
      if (mounted) setState(() => _favoriteError = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(Comic comic) async {
    final selected = comic.chapters.map((c) => c.id).toSet();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(S.of(context).comicChooseChapters),
          content: SizedBox(
            width: 420,
            height: 340,
            child: ListView(
              children: [
                for (final chapter in comic.chapters)
                  CheckboxListTile(
                    title: Text(chapter.title),
                    value: selected.contains(chapter.id),
                    onChanged: (value) => setDialog(() {
                      if (value == true) {
                        selected.add(chapter.id);
                      } else {
                        selected.remove(chapter.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(S.of(context).cancel),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(S.of(context).comicDownloadSelected),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(comicDownloadsProvider)
          .enqueue(
            comic,
            comic.chapters.where((c) => selected.contains(c.id)).toList(),
          );
      if (mounted) SnackBarUtil.showSuccess(context, S.of(context).comicQueued);
    } catch (e) {
      if (mounted) SnackBarUtil.showError(context, e.toString());
    }
  }

  void _comments(Comic comic) {
    final source = ref
        .read(comicSourcesProvider)
        .firstWhere((s) => s.key == comic.source);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            _CommentsScreen(comic: comic, load: () => source.comments(comic)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return GlobalAudioPlayerWrapper.workDetails(
      child: Scaffold(
        appBar: ScrollableAppBar(
          systemOverlayStyle: transparentSystemBarsForBrightness(
            Theme.of(context).brightness,
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            _comic.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          actions: [
            IconButton(
              tooltip: s.download,
              icon: const Icon(Icons.download),
              onPressed: _chapters.isEmpty
                  ? null
                  : () => _download(_readyComic),
            ),
            IconButton(
              tooltip: s.comicFavorites,
              icon: const Icon(Icons.bookmark_add_outlined),
              onPressed: _busy ? null : () => _favorite(_readyComic),
            ),
          ],
        ),
        body: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final s = S.of(context);
    final comic = _readyComic;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final wide = width >= 700;
        final coverWidth = wide
            ? (width * .27).clamp(180.0, 340.0)
            : (width * .3).clamp(92.0, 150.0);
        final cover = SizedBox(
          key: const ValueKey('comic-detail-cover'),
          width: coverWidth,
          height: coverWidth * 1.5,
          child: WorkCoverHeroFrame(
            heroTag: comicCoverHeroTag(widget.comic),
            child: ComicImage(
              source: widget.comic.source,
              page: _comic.coverPage.localPath == null
                  ? widget.comic.coverPage
                  : _comic.coverPage,
              fit: BoxFit.contain,
            ),
          ),
        );
        final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            WorkTitleHeader(title: comic.title, showTranslateButton: false),
            const SizedBox(height: 8),
            Text(
              ref
                  .read(comicSourcesProvider)
                  .firstWhere((s) => s.key == comic.source)
                  .name,
            ),
            if (comic.rating != null) Text('${s.ratingLabel}: ${comic.rating}'),
            if (comic.extra['likes'] != null)
              Row(
                children: [
                  const Icon(Icons.thumb_up_alt_outlined, size: 16),
                  const SizedBox(width: 4),
                  Text('${comic.extra['likes']}'),
                ],
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _chapters.isEmpty ? null : () => _read(comic),
              icon: const Icon(Icons.menu_book),
              label: Text(s.comicContinue),
            ),
          ],
        );
        return SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        cover,
                        const SizedBox(width: 16),
                        Expanded(child: info),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_busy) const LinearProgressIndicator(),
                    if (_favoriteError != null)
                      _retryBanner(_favoriteError!, () => _favorite(comic)),
                    if (_metadataLoading) const LinearProgressIndicator(),
                    if (_metadataError != null)
                      _retryBanner(_metadataError!, _loadMetadata),
                    const SizedBox(height: 16),
                    SelectableText(comic.description),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: comic.tags
                          .map(
                            (tag) => MetadataSearchChip(
                              label: tag,
                              searchKeyword: tag,
                              searchTypeLabel: s.tagLabel,
                              searchParams: const {},
                              chipTone: MetadataChipTone.primary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              borderRadius: 6,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ComicSearchScreen(
                                    initialSource: comic.source,
                                    initialQuery: tag,
                                  ),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                    if (ref
                        .read(comicSourcesProvider)
                        .firstWhere((source) => source.key == comic.source)
                        .hasComments) ...[
                      const SizedBox(height: 16),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          s.comicComments,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _comments(comic),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      s.comicChapters,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (_chaptersLoading) const LinearProgressIndicator(),
                    if (_chaptersError != null)
                      _retryBanner(_chaptersError!, _loadChapters),
                    for (final chapter in _chapters)
                      ListTile(
                        title: Text(chapter.title),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _read(comic, chapter: chapter),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _retryBanner(Object error, VoidCallback retry) => MaterialBanner(
    content: Text('$error'),
    actions: [TextButton(onPressed: retry, child: Text(S.of(context).retry))],
  );
}

class _CommentsScreen extends StatefulWidget {
  const _CommentsScreen({required this.comic, required this.load});
  final Comic comic;
  final Future<List<ComicComment>> Function() load;
  @override
  State<_CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends State<_CommentsScreen> {
  late Future<List<ComicComment>> _comments = widget.load();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(S.of(context).comicComments)),
    body: FutureBuilder<List<ComicComment>>(
      future: _comments,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ComicErrorView(
            error: snapshot.error!,
            retry: () => setState(() => _comments = widget.load()),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          children: [
            for (final c in snapshot.data!)
              ListTile(
                title: Text(c.author),
                subtitle: Text(c.text),
                trailing: c.score == null ? null : Text(c.score!),
              ),
          ],
        );
      },
    ),
  );
}
