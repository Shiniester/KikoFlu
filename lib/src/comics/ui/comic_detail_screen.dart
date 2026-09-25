import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/app_localizations.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../../widgets/scrollable_appbar.dart';
import '../../widgets/metadata_search_chip.dart';
import '../../widgets/work_detail/work_detail_responsive_layout.dart';
import '../../widgets/work_detail/work_title_header.dart';
import '../../utils/system_ui_style.dart';
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
  late Future<Comic> _details;
  bool _busy = false;
  Object? _favoriteError;
  bool _favoriteLocal = false;
  void _load() {
    _details = _getDetails();
  }

  Future<Comic> _getDetails() async {
    final downloads = ref.read(comicDownloadsProvider);
    await downloads.ready;
    final saved = downloads.completedComics
        .where((c) => c.key == widget.comic.key)
        .firstOrNull;
    if (saved != null) return saved;
    try {
      return await ref
          .read(comicSourcesProvider)
          .firstWhere((s) => s.key == widget.comic.source)
          .details(widget.comic.id);
    } catch (_) {
      final offline = downloads.completedComics
          .where((c) => c.key == widget.comic.key)
          .firstOrNull;
      if (offline != null) return offline;
      rethrow;
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
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

  Future<void> _favorite(Comic comic, {bool local = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _favoriteError = null;
      _favoriteLocal = local;
    });
    try {
      final source = ref
          .read(comicSourcesProvider)
          .firstWhere((s) => s.key == comic.source);
      if (!local && source.hasRemoteFavorites && source.isLoggedIn) {
        await source.setFavorite(comic, true);
        if (mounted) {
          ref.read(comicRemoteFavoritesRevisionProvider.notifier).state++;
        }
      } else {
        await ref.read(comicLibraryProvider).favorite(comic, true);
      }
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
      child: FutureBuilder<Comic>(
        future: _details,
        builder: (context, snapshot) => Scaffold(
          appBar: ScrollableAppBar(
            systemOverlayStyle: transparentSystemBarsForBrightness(
              Theme.of(context).brightness,
            ),
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: Text(
              widget.comic.title,
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
                onPressed:
                    snapshot.hasData && snapshot.data!.chapters.isNotEmpty
                    ? () => _download(snapshot.data!)
                    : null,
              ),
              IconButton(
                tooltip: s.comicFavorites,
                icon: const Icon(Icons.bookmark_add_outlined),
                onPressed: _busy || !snapshot.hasData
                    ? null
                    : () => _favorite(snapshot.data!),
              ),
            ],
          ),
          body: _buildBody(context, snapshot),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, AsyncSnapshot<Comic> snapshot) {
    final s = S.of(context);
    if (snapshot.hasError) {
      return ComicErrorView(
        error: snapshot.error!,
        retry: () => setState(_load),
      );
    }
    if (!snapshot.hasData) {
      return const Center(child: CircularProgressIndicator());
    }
    final comic = snapshot.data!;
    return WorkDetailResponsiveLayout(
      coverBuilder: (context, isLandscape) => Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
            height: isLandscape ? MediaQuery.sizeOf(context).height * .65 : 280,
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ComicImage(
                  source: comic.source,
                  page: comic.coverPage,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
        ),
      ),
      info: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
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
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: comic.chapters.isEmpty ? null : () => _read(comic),
                  icon: const Icon(Icons.menu_book),
                  label: Text(s.comicContinue),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _favorite(comic, local: true),
                  child: Text(s.comicSaveLocal),
                ),
                if (ref
                    .read(comicSourcesProvider)
                    .firstWhere((s) => s.key == comic.source)
                    .hasComments)
                  TextButton(
                    onPressed: () => _comments(comic),
                    child: Text(s.comicComments),
                  ),
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_favoriteError != null)
              MaterialBanner(
                content: Text('$_favoriteError'),
                actions: [
                  TextButton(
                    onPressed: () => _favorite(comic, local: _favoriteLocal),
                    child: Text(s.retry),
                  ),
                ],
              ),
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
            const SizedBox(height: 16),
            Text(
              s.comicChapters,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final chapter in comic.chapters)
              ListTile(
                title: Text(chapter.title),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _read(comic, chapter: chapter),
              ),
          ],
        ),
      ),
    );
  }
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
