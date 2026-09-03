import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../providers/lyric_provider.dart';
import '../../providers/player_subtitle_candidates_provider.dart';
import '../../utils/snackbar_util.dart';
import 'player_glass_surface.dart';

Future<void> showPlayerSubtitlePickerSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    builder: (_) => const PlayerBackdropGroup(
      child: PlayerTransientGlassSurface(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        child: _PlayerSubtitlePickerSheet(),
      ),
    ),
  );
}

class _PlayerSubtitlePickerSheet extends ConsumerStatefulWidget {
  const _PlayerSubtitlePickerSheet();

  @override
  ConsumerState<_PlayerSubtitlePickerSheet> createState() =>
      _PlayerSubtitlePickerSheetState();
}

class _PlayerSubtitlePickerSheetState
    extends ConsumerState<_PlayerSubtitlePickerSheet> {
  bool _showAll = false;
  String? _loadingIdentity;

  @override
  Widget build(BuildContext context) {
    final candidates = ref.watch(playerSubtitleCandidatesProvider);
    final source = ref.watch(
      lyricControllerProvider.select((state) => state.source),
    );
    final colorScheme = Theme.of(context).colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.72;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      S.of(context).playerSubtitleSelection,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Flexible(
                child: candidates.when(
                  loading: () => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                  error: (error, _) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        error.toString(),
                        style: TextStyle(color: colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                  data: (items) {
                    final matching = items
                        .where((item) => item.matchesCurrentAudio)
                        .toList(growable: false);
                    final showAll = _showAll || matching.isEmpty;
                    final visible = showAll ? items : matching;
                    if (items.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            S.of(context).playerSubtitleNoCandidates,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      );
                    }
                    return ListView.builder(
                      key: const ValueKey('player-subtitle-candidate-list'),
                      shrinkWrap: true,
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final candidate = visible[index];
                        final current = candidate.matchesSource(source);
                        final loading = _loadingIdentity == candidate.identity;
                        return ListTile(
                          key: ValueKey(
                            'player-subtitle-candidate-${candidate.identity}',
                          ),
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          leading: Icon(
                            candidate.origin ==
                                    PlayerSubtitleCandidateOrigin.library
                                ? Icons.video_library_outlined
                                : Icons.folder_outlined,
                            size: 21,
                            color: current ? colorScheme.primary : null,
                          ),
                          title: Text(
                            candidate.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.15,
                              fontWeight: current
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            '${_originLabel(context, candidate.origin)} · '
                            '${candidate.pathLabel}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          trailing: loading
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : current
                              ? Icon(Icons.check, color: colorScheme.primary)
                              : !candidate.matchesCurrentAudio
                              ? Tooltip(
                                  message: S
                                      .of(context)
                                      .playerSubtitleMayNotMatch,
                                  child: Icon(
                                    Icons.info_outline,
                                    size: 18,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                )
                              : null,
                          enabled: _loadingIdentity == null && !current,
                          onTap: () => _select(candidate),
                        );
                      },
                    );
                  },
                ),
              ),
              candidates.maybeWhen(
                data: (items) {
                  final hasUnmatched = items.any(
                    (item) => !item.matchesCurrentAudio,
                  );
                  if (!hasUnmatched) return const SizedBox.shrink();
                  final hasMatching = items.any(
                    (item) => item.matchesCurrentAudio,
                  );
                  if (!hasMatching) return const SizedBox.shrink();
                  final showingAll = _showAll || !hasMatching;
                  return Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      key: const ValueKey('player-subtitle-show-all'),
                      onPressed: _loadingIdentity == null
                          ? () => setState(() => _showAll = !showingAll)
                          : null,
                      icon: Icon(
                        showingAll ? Icons.filter_alt : Icons.list_alt,
                        size: 18,
                      ),
                      label: Text(
                        showingAll
                            ? S.of(context).playerSubtitleShowMatches
                            : S.of(context).playerSubtitleShowAll,
                      ),
                    ),
                  );
                },
                orElse: () => const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _select(PlayerSubtitleCandidate candidate) async {
    if (_loadingIdentity != null) return;
    setState(() => _loadingIdentity = candidate.identity);
    try {
      await ref
          .read(lyricControllerProvider.notifier)
          .selectLyricManually(
            candidate.source,
            workId: candidate.source['workId'] as int?,
          );
      if (!mounted) return;
      SnackBarUtil.showSuccess(
        context,
        S.of(context).subtitleLoadSuccess(candidate.title),
      );
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadingIdentity = null);
      SnackBarUtil.showError(
        context,
        S
            .of(context)
            .subtitleLoadFailed(
              error.toString().replaceFirst('Bad state: ', ''),
            ),
      );
    }
  }

  String _originLabel(
    BuildContext context,
    PlayerSubtitleCandidateOrigin origin,
  ) => switch (origin) {
    PlayerSubtitleCandidateOrigin.work =>
      S.of(context).playerSubtitleSourceWork,
    PlayerSubtitleCandidateOrigin.library =>
      S.of(context).playerSubtitleSourceLibrary,
  };
}
