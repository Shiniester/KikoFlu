import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/audio_slice.dart';
import '../../providers/audio_provider.dart';
import '../../utils/snackbar_util.dart';
import '../../utils/string_utils.dart';
import '../responsive_dialog.dart';

String formatAudioSliceTime(int milliseconds) =>
    '${formatDuration(Duration(milliseconds: milliseconds), padHours: false)}.'
    '${(milliseconds % 1000).toString().padLeft(3, '0')}';

int? parseAudioSliceTime(String text) {
  final match = RegExp(
    r'^(?:(\d+):)?(\d+):([0-5]?\d)(?:\.(\d{1,3}))?$',
  ).firstMatch(text.trim());
  if (match == null) return null;
  final hours = int.tryParse(match[1] ?? '0');
  final minutes = int.tryParse(match[2]!);
  if (hours == null || minutes == null || (match[1] != null && minutes > 59)) {
    return null;
  }
  return ((hours * 60 + minutes) * 60 + int.parse(match[3]!)) * 1000 +
      int.parse((match[4] ?? '0').padRight(3, '0'));
}

class PlayerSliceCutButton extends ConsumerWidget {
  const PlayerSliceCutButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(audioSliceStateProvider).valueOrNull;
    final duration = ref.watch(durationProvider).valueOrNull;
    final loading = ref.watch(isTrackLoadingProvider).valueOrNull ?? false;
    final hasStart = state?.pendingStartMs != null;
    return IconButton(
      key: const ValueKey('player-slice-cut-button'),
      tooltip: hasStart
          ? S.of(context).markAudioSliceEnd
          : S.of(context).markAudioSliceStart,
      color: hasStart ? Theme.of(context).colorScheme.primary : null,
      onPressed:
          state?.trackKey == null ||
              state!.isLoading ||
              loading ||
              duration == null ||
              duration <= Duration.zero
          ? null
          : () async {
              final saved = await ref
                  .read(audioPlayerServiceProvider)
                  .markSlice();
              if (!saved && context.mounted) {
                SnackBarUtil.showError(
                  context,
                  S.of(context).audioSliceSaveFailed,
                );
              }
            },
      icon: const Icon(Icons.content_cut),
    );
  }
}

class PlayerSliceManagerButton extends ConsumerWidget {
  const PlayerSliceManagerButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(audioSliceStateProvider).valueOrNull;
    final loading = ref.watch(isTrackLoadingProvider).valueOrNull ?? false;
    return IconButton(
      key: const ValueKey('player-slice-manager-button'),
      tooltip: S.of(context).manageAudioSlices,
      onPressed: state?.trackKey == null || state!.isLoading || loading
          ? null
          : () => showPlayerSliceManager(context),
      icon: Badge(
        isLabelVisible: state?.onlySlices ?? false,
        child: const Icon(Icons.splitscreen_outlined),
      ),
    );
  }
}

Future<void> showPlayerSliceManager(
  BuildContext context, {
  AudioSlice? initialSlice,
}) => showResponsiveBottomSheet<void>(
  context: context,
  maxWidth: 560,
  builder: (_) => _PlayerSliceManager(initialSlice: initialSlice),
);

class _PlayerSliceManager extends ConsumerWidget {
  const _PlayerSliceManager({this.initialSlice});

  final AudioSlice? initialSlice;

  Future<void> _edit(
    BuildContext context,
    String trackKey,
    AudioSlice slice,
    Duration duration,
  ) => showDialog<void>(
    context: context,
    builder: (_) =>
        _AudioSliceEditor(trackKey: trackKey, slice: slice, duration: duration),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref.watch(audioSliceStateProvider).valueOrNull ??
        const AudioSliceState();
    final service = ref.read(audioPlayerServiceProvider);
    final l10n = S.of(context);
    final duration = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final track = ref.watch(currentTrackProvider).valueOrNull;
    final trackKey = state.trackKey;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.audioSlices,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const PlayerSliceCutButton(),
                    IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                if (track != null)
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                SwitchListTile(
                  key: const ValueKey('player-only-slices-switch'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.onlyPlayAudioSlices),
                  value: state.onlySlices,
                  onChanged: service.setOnlySlices,
                ),
                if (state.pendingStartMs case final start?)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      l10n.audioSlicePendingStart(formatAudioSliceTime(start)),
                    ),
                    trailing: IconButton(
                      tooltip: l10n.cancelAudioSliceStart,
                      onPressed: service.cancelSliceStart,
                      icon: const Icon(Icons.close),
                    ),
                  ),
                if (state.isLoading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (state.slices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      l10n.audioSlicesEmpty,
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: state.slices.length,
                    itemBuilder: (context, index) {
                      final slice = state.slices[index];
                      final previewing = state.preview == slice;
                      return ListTile(
                        key: ValueKey(
                          'audio-slice-${slice.startMs}-${slice.endMs}',
                        ),
                        contentPadding: EdgeInsets.zero,
                        selected: slice == initialSlice,
                        title: Text(
                          l10n.audioSliceRange(
                            formatAudioSliceTime(slice.startMs),
                            formatAudioSliceTime(slice.endMs),
                          ),
                          maxLines: 2,
                        ),
                        onTap: () => ref
                            .read(audioPlayerControllerProvider.notifier)
                            .seekAndPersist(
                              Duration(milliseconds: slice.startMs),
                            ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: previewing
                                  ? l10n.stopAudioSlicePreview
                                  : l10n.previewAudioSlice,
                              onPressed: trackKey == null
                                  ? null
                                  : () async {
                                      if (previewing) {
                                        service.cancelSlicePreview();
                                        await ref
                                            .read(
                                              audioPlayerControllerProvider
                                                  .notifier,
                                            )
                                            .pause();
                                        return;
                                      }
                                      try {
                                        await service.previewSlice(
                                          trackKey,
                                          slice,
                                        );
                                      } catch (_) {
                                        if (context.mounted) {
                                          SnackBarUtil.showError(
                                            context,
                                            l10n.audioSlicePreviewFailed,
                                          );
                                        }
                                      }
                                    },
                              icon: Icon(
                                previewing ? Icons.stop : Icons.play_arrow,
                              ),
                            ),
                            PopupMenuButton<String>(
                              enabled: trackKey != null,
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'edit',
                                  enabled: duration > Duration.zero,
                                  child: Text(l10n.edit),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text(l10n.delete),
                                ),
                              ],
                              onSelected: (action) async {
                                if (trackKey == null) return;
                                if (action == 'edit') {
                                  await _edit(
                                    context,
                                    trackKey,
                                    slice,
                                    duration,
                                  );
                                } else if (!await service.deleteSlice(
                                      trackKey,
                                      slice,
                                    ) &&
                                    context.mounted) {
                                  SnackBarUtil.showError(
                                    context,
                                    l10n.audioSliceDeleteFailed,
                                  );
                                }
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                if (state.slices.isNotEmpty)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      onPressed: trackKey == null
                          ? null
                          : () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (context) => ResponsiveAlertDialog(
                                  title: Text(l10n.clearAudioSlices),
                                  content: Text(l10n.clearAudioSlicesConfirm),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: Text(l10n.cancel),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: Text(l10n.clear),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed == true &&
                                  !await service.clearSlices(trackKey) &&
                                  context.mounted) {
                                SnackBarUtil.showError(
                                  context,
                                  l10n.audioSliceDeleteFailed,
                                );
                              }
                            },
                      child: Text(l10n.clearAudioSlices),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AudioSliceEditor extends ConsumerStatefulWidget {
  const _AudioSliceEditor({
    required this.trackKey,
    required this.slice,
    required this.duration,
  });

  final String trackKey;
  final AudioSlice slice;
  final Duration duration;

  @override
  ConsumerState<_AudioSliceEditor> createState() => _AudioSliceEditorState();
}

class _AudioSliceEditorState extends ConsumerState<_AudioSliceEditor> {
  late final _start = TextEditingController(
    text: formatAudioSliceTime(widget.slice.startMs),
  );
  late final _end = TextEditingController(
    text: formatAudioSliceTime(widget.slice.endMs),
  );
  late RangeValues _range = RangeValues(
    widget.slice.startMs.toDouble(),
    widget.slice.endMs.toDouble(),
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  void _textChanged(String _) {
    final start = parseAudioSliceTime(_start.text);
    final end = parseAudioSliceTime(_end.text);
    if (start != null &&
        end != null &&
        start < end &&
        end <= widget.duration.inMilliseconds) {
      setState(() {
        _range = RangeValues(start.toDouble(), end.toDouble());
        _error = null;
      });
    }
  }

  Future<void> _save() async {
    final start = parseAudioSliceTime(_start.text);
    final end = parseAudioSliceTime(_end.text);
    if (start == null || end == null) {
      setState(() => _error = S.of(context).audioSliceInvalidTime);
      return;
    }
    setState(() => _saving = true);
    final saved = await ref
        .read(audioPlayerServiceProvider)
        .saveSlice(
          trackKey: widget.trackKey,
          slice: AudioSlice(startMs: start, endMs: end),
          replacing: widget.slice,
        );
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = S.of(context).audioSliceSaveFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = S.of(context);
    final state = ref.watch(audioSliceStateProvider).valueOrNull;
    final sameTrack = state?.trackKey == widget.trackKey;
    return ResponsiveAlertDialog(
      title: Text(l10n.editAudioSlice),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RangeSlider(
              key: const ValueKey('audio-slice-range-editor'),
              semanticFormatterCallback: (value) =>
                  formatAudioSliceTime(value.round()),
              max: widget.duration.inMilliseconds.toDouble(),
              values: RangeValues(
                _range.start.clamp(
                  0.0,
                  widget.duration.inMilliseconds.toDouble(),
                ),
                _range.end.clamp(
                  0.0,
                  widget.duration.inMilliseconds.toDouble(),
                ),
              ),
              labels: RangeLabels(
                formatAudioSliceTime(_range.start.round()),
                formatAudioSliceTime(_range.end.round()),
              ),
              onChanged: _saving || !sameTrack
                  ? null
                  : (range) {
                      setState(() {
                        _range = range;
                        _start.text = formatAudioSliceTime(range.start.round());
                        _end.text = formatAudioSliceTime(range.end.round());
                        _error = null;
                      });
                    },
            ),
            TextField(
              key: const ValueKey('audio-slice-start-time'),
              controller: _start,
              enabled: !_saving && sameTrack,
              decoration: InputDecoration(
                labelText: l10n.audioSliceStartTime,
                hintText: '00:00.000',
              ),
              onChanged: _textChanged,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('audio-slice-end-time'),
              controller: _end,
              enabled: !_saving && sameTrack,
              decoration: InputDecoration(
                labelText: l10n.audioSliceEndTime,
                hintText: '00:30.000',
              ),
              onChanged: _textChanged,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: _saving || !sameTrack ? null : _save,
          child: Text(l10n.save),
        ),
      ],
    );
  }
}
