import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../utils/snackbar_util.dart';
import '../comic_models.dart';
import '../comic_providers.dart';

Future<void> saveComicFavorite(WidgetRef ref, Comic comic) async {
  final source = ref
      .read(comicSourcesProvider)
      .firstWhere((s) => s.key == comic.source);
  final library = ref.read(comicLibraryProvider);
  if (source.hasRemoteFavorites && source.isLoggedIn) {
    await source.setFavorite(comic, true);
    if (ref.context.mounted) {
      ref.read(comicRemoteFavoritesRevisionProvider.notifier).state++;
    }
  }
  await library.favorite(comic, true);
}

Future<void> downloadComicChapters(
  BuildContext context,
  WidgetRef ref,
  Comic comic, {
  String? initialChapterId,
}) async {
  if (comic.chapters.isEmpty) return;
  final selected = comic.chapters
      .where((c) => initialChapterId == null || c.id == initialChapterId)
      .map((c) => c.id)
      .toSet();
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
  if (confirmed != true || !context.mounted) return;
  try {
    await ref
        .read(comicDownloadsProvider)
        .enqueue(
          comic,
          comic.chapters.where((c) => selected.contains(c.id)).toList(),
        );
    if (context.mounted) {
      SnackBarUtil.showSuccess(context, S.of(context).comicQueued);
    }
  } catch (e) {
    if (context.mounted) SnackBarUtil.showError(context, e.toString());
  }
}
