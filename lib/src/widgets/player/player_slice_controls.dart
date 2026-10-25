import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/audio_slice.dart';
import '../../providers/audio_provider.dart';
import '../../providers/audio_slice_presentation_provider.dart';
import '../../services/audio_player_service.dart';
import '../../utils/snackbar_util.dart';
import '../../utils/string_utils.dart';
import '../responsive_dialog.dart';
import 'player_slice_progress.dart';

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
          : () => showPlayerSliceManager(context, trackKey: state.trackKey),
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
  String? trackKey,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final selection = container.read(audioSliceSelectionProvider.notifier);
  final state = container.read(audioSliceStateProvider).valueOrNull;
  selection.state =
      initialSlice != null &&
          trackKey != null &&
          state?.trackKey == trackKey &&
          state!.slices.contains(initialSlice)
      ? AudioSliceSelection(trackKey: trackKey, slice: initialSlice)
      : null;
  try {
    await showResponsiveBottomSheet<void>(
      context: context,
      maxWidth: 560,
      builder: (_) => const _PlayerSliceManager(),
    );
  } finally {
    selection.state = null;
  }
}

class _PlayerSliceManager extends ConsumerStatefulWidget {
  const _PlayerSliceManager();

  @override
  ConsumerState<_PlayerSliceManager> createState() =>
      _PlayerSliceManagerState();
}

class _PlayerSliceManagerState extends ConsumerState<_PlayerSliceManager> {
  final _scrollController = ScrollController();
  final _rowKeys = <AudioSlice, GlobalKey>{};
  int _trackChangeGeneration = 0;

  void _clearSelectionForTrackChange() {
    _trackChangeGeneration++;
    ref.read(audioSliceSelectionProvider.notifier).state = null;
  }

  Future<AudioSlice?> _edit(
    BuildContext context,
    String trackKey,
    AudioSlice slice,
    Duration duration,
  ) => showDialog<AudioSlice?>(
    context: context,
    builder: (_) =>
        _AudioSliceEditor(trackKey: trackKey, slice: slice, duration: duration),
  );

  bool _ownsTrack(String trackKey) {
    final state = ref.read(audioSliceStateProvider).valueOrNull;
    final service = ref.read(audioPlayerServiceProvider);
    return state?.trackKey == trackKey &&
        service.sliceState.trackKey == trackKey &&
        !state!.isLoading &&
        !(ref.read(isTrackLoadingProvider).valueOrNull ?? false) &&
        ref.read(currentTrackProvider).valueOrNull != null;
  }

  void _select(AudioSlice? slice, String trackKey) {
    if (!_ownsTrack(trackKey)) return;
    final state = ref.read(audioSliceStateProvider).valueOrNull;
    if (slice != null && !state!.slices.contains(slice)) return;
    ref.read(audioSliceSelectionProvider.notifier).state = slice == null
        ? null
        : AudioSliceSelection(trackKey: trackKey, slice: slice);
    if (slice != null) _scrollToSlice(slice);
  }

  void _scrollToSlice(AudioSlice slice) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _rowKeys[slice]?.currentContext;
      if (mounted && context != null) {
        unawaited(Scrollable.ensureVisible(context, alignment: 0.5));
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentTrackProvider, (previous, next) {
      final previousTrack = previous?.valueOrNull;
      final nextTrack = next.valueOrNull;
      if (previousTrack != null &&
          nextTrack != null &&
          previousTrack != nextTrack) {
        _clearSelectionForTrackChange();
      }
    });
    ref.listen(audioSliceStateProvider, (previous, next) {
      final selection = ref.read(audioSliceSelectionProvider);
      final previousState = previous?.valueOrNull;
      final state = next.valueOrNull;
      if (previousState?.trackKey != null &&
          previousState?.trackKey != state?.trackKey) {
        _clearSelectionForTrackChange();
      }
      if (selection != null &&
          (state?.trackKey != selection.trackKey ||
              !state!.slices.contains(selection.slice))) {
        ref.read(audioSliceSelectionProvider.notifier).state = null;
      }
    });
    final state =
        ref.watch(audioSliceStateProvider).valueOrNull ??
        const AudioSliceState();
    final service = ref.read(audioPlayerServiceProvider);
    final l10n = S.of(context);
    final duration = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final track = ref.watch(currentTrackProvider).valueOrNull;
    final trackKey = state.trackKey;
    final trackAvailable =
        trackKey != null &&
        !state.isLoading &&
        !(ref.watch(isTrackLoadingProvider).valueOrNull ?? false) &&
        track != null;
    final activeSlice = ref.watch(activeAudioSliceProvider);
    final selectedSlice = ref.watch(selectedAudioSliceProvider);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
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
                Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (duration > Duration.zero && trackKey != null) ...[
                const SizedBox(height: 8),
                _AudioSliceTimeline(
                  key: ValueKey('audio-slice-manager-timeline-$trackKey'),
                  trackKey: trackKey,
                  duration: duration,
                  slices: state.slices,
                  enabled: trackAvailable,
                  activeSlice: activeSlice,
                  selectedSlice: selectedSlice,
                  onSelectionChanged: (slice) => _select(slice, trackKey),
                ),
              ],
              Flexible(
                fit: FlexFit.loose,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
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
                            l10n.audioSlicePendingStart(
                              formatAudioSliceTime(start),
                            ),
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
                            final selected = slice == selectedSlice;
                            final active = slice == activeSlice;
                            final rowKey = _rowKeys.putIfAbsent(
                              slice,
                              GlobalKey.new,
                            );
                            return Builder(
                              key: rowKey,
                              builder: (context) => ListTile(
                                key: ValueKey(
                                  'audio-slice-${slice.startMs}-${slice.endMs}',
                                ),
                                contentPadding: EdgeInsets.zero,
                                selected: selected,
                                leading: Icon(
                                  selected
                                      ? Icons.check_circle
                                      : active
                                      ? Icons.play_arrow
                                      : Icons.graphic_eq,
                                ),
                                title: Text(
                                  l10n.audioSliceRange(
                                    formatAudioSliceTime(slice.startMs),
                                    formatAudioSliceTime(slice.endMs),
                                  ),
                                  maxLines: 2,
                                ),
                                subtitle: Visibility(
                                  visible: active || selected,
                                  maintainSize: true,
                                  maintainAnimation: true,
                                  maintainState: true,
                                  child: Text(
                                    active
                                        ? l10n.audioSliceCurrent
                                        : l10n.audioSliceSelected,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                onTap: !trackAvailable
                                    ? null
                                    : () async {
                                        final selectedTrackKey = trackKey;
                                        if (!_ownsTrack(selectedTrackKey)) {
                                          return;
                                        }
                                        _select(slice, selectedTrackKey);
                                        await ref
                                            .read(
                                              audioPlayerControllerProvider
                                                  .notifier,
                                            )
                                            .seekAndPersist(
                                              Duration(
                                                milliseconds: slice.startMs,
                                              ),
                                            );
                                      },
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: previewing
                                          ? l10n.stopAudioSlicePreview
                                          : l10n.previewAudioSlice,
                                      onPressed: !trackAvailable
                                          ? null
                                          : () async {
                                              final previewTrackKey = trackKey;
                                              if (!_ownsTrack(
                                                previewTrackKey,
                                              )) {
                                                return;
                                              }
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
                                                  previewTrackKey,
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
                                        previewing
                                            ? Icons.stop
                                            : Icons.play_arrow,
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      enabled: trackAvailable,
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
                                        if (!trackAvailable ||
                                            !_ownsTrack(trackKey)) {
                                          return;
                                        }
                                        final actionTrackKey = trackKey;
                                        if (action == 'edit') {
                                          final trackChangeGeneration =
                                              _trackChangeGeneration;
                                          final edited = await _edit(
                                            context,
                                            actionTrackKey,
                                            slice,
                                            duration,
                                          );
                                          if (edited == null ||
                                              !mounted ||
                                              _trackChangeGeneration !=
                                                  trackChangeGeneration ||
                                              !_ownsTrack(actionTrackKey)) {
                                            return;
                                          }
                                          final updated = ref
                                              .read(audioSliceStateProvider)
                                              .valueOrNull;
                                          if (updated?.trackKey ==
                                                  actionTrackKey &&
                                              updated!.slices.contains(
                                                edited,
                                              )) {
                                            ref
                                                .read(
                                                  audioSliceSelectionProvider
                                                      .notifier,
                                                )
                                                .state = AudioSliceSelection(
                                              trackKey: actionTrackKey,
                                              slice: edited,
                                            );
                                            _scrollToSlice(edited);
                                          }
                                        } else {
                                          final deleted = await service
                                              .deleteSlice(
                                                actionTrackKey,
                                                slice,
                                              );
                                          if (!deleted && context.mounted) {
                                            SnackBarUtil.showError(
                                              context,
                                              l10n.audioSliceDeleteFailed,
                                            );
                                          } else if (deleted) {
                                            final selection = ref.read(
                                              audioSliceSelectionProvider,
                                            );
                                            if (selection?.trackKey ==
                                                    actionTrackKey &&
                                                selection?.slice == slice) {
                                              ref
                                                      .read(
                                                        audioSliceSelectionProvider
                                                            .notifier,
                                                      )
                                                      .state =
                                                  null;
                                            }
                                          }
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      if (state.slices.isNotEmpty)
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: TextButton(
                            onPressed: !trackAvailable
                                ? null
                                : () async {
                                    final confirmed = await showDialog<bool>(
                                      context: context,
                                      builder: (context) =>
                                          ResponsiveAlertDialog(
                                            title: Text(l10n.clearAudioSlices),
                                            content: Text(
                                              l10n.clearAudioSlicesConfirm,
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  false,
                                                ),
                                                child: Text(l10n.cancel),
                                              ),
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  true,
                                                ),
                                                child: Text(l10n.clear),
                                              ),
                                            ],
                                          ),
                                    );
                                    if (confirmed == true) {
                                      final cleared = await service.clearSlices(
                                        trackKey,
                                      );
                                      if (!cleared && context.mounted) {
                                        SnackBarUtil.showError(
                                          context,
                                          l10n.audioSliceDeleteFailed,
                                        );
                                      } else if (cleared) {
                                        if (ref
                                                .read(
                                                  audioSliceSelectionProvider,
                                                )
                                                ?.trackKey ==
                                            trackKey) {
                                          ref
                                                  .read(
                                                    audioSliceSelectionProvider
                                                        .notifier,
                                                  )
                                                  .state =
                                              null;
                                        }
                                      }
                                    }
                                  },
                            child: Text(l10n.clearAudioSlices),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AudioSliceTimeline extends ConsumerStatefulWidget {
  const _AudioSliceTimeline({
    super.key,
    required this.trackKey,
    required this.duration,
    required this.slices,
    required this.enabled,
    required this.activeSlice,
    required this.selectedSlice,
    required this.onSelectionChanged,
  });

  final String trackKey;
  final Duration duration;
  final List<AudioSlice> slices;
  final bool enabled;
  final AudioSlice? activeSlice;
  final AudioSlice? selectedSlice;
  final ValueChanged<AudioSlice?> onSelectionChanged;

  @override
  ConsumerState<_AudioSliceTimeline> createState() =>
      _AudioSliceTimelineState();
}

class _AudioSliceTimelineState extends ConsumerState<_AudioSliceTimeline> {
  late final AudioPlayerService _service;
  bool _scrubbing = false;
  double? _dragValue;
  int _scrubGeneration = 0;

  @override
  void initState() {
    super.initState();
    _service = ref.read(audioPlayerServiceProvider);
  }

  bool _ownsTrack() {
    final state = ref.read(audioSliceStateProvider).valueOrNull;
    return widget.enabled &&
        state?.trackKey == widget.trackKey &&
        ref.read(audioPlayerServiceProvider).sliceState.trackKey ==
            widget.trackKey &&
        !(ref.read(isTrackLoadingProvider).valueOrNull ?? false) &&
        ref.read(currentTrackProvider).valueOrNull != null;
  }

  AudioSlice? _sliceAt(int milliseconds) {
    for (final slice in widget.slices) {
      if (milliseconds >= slice.startMs && milliseconds < slice.endMs) {
        return slice;
      }
    }
    return null;
  }

  void _endScrubbing([int? generation]) {
    if (!_scrubbing || (generation != null && generation != _scrubGeneration)) {
      return;
    }
    _scrubbing = false;
    _scrubGeneration++;
    ref.read(audioPlayerServiceProvider).setSliceScrubbing(false);
    if (mounted) setState(() => _dragValue = null);
  }

  Future<void> _commitScrub(double value) async {
    if (!_scrubbing) return;
    final generation = _scrubGeneration;
    final milliseconds = value
        .round()
        .clamp(0, widget.duration.inMilliseconds)
        .toInt();
    try {
      if (_ownsTrack()) {
        widget.onSelectionChanged(_sliceAt(milliseconds));
        await ref
            .read(audioPlayerControllerProvider.notifier)
            .seekAndPersist(Duration(milliseconds: milliseconds));
      }
    } finally {
      _endScrubbing(generation);
    }
  }

  @override
  void dispose() {
    if (_scrubbing) {
      _scrubbing = false;
      _scrubGeneration++;
      _service.setSliceScrubbing(false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = S.of(context);
    final durationMs = widget.duration.inMilliseconds;
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final onlySlices =
        ref.watch(audioSliceStateProvider).valueOrNull?.onlySlices ?? false;
    final currentMs = position.inMilliseconds.clamp(0, durationMs).toInt();
    final displayMs = (_dragValue?.round() ?? currentMs)
        .clamp(0, durationMs)
        .toInt();
    final activeSlice = _scrubbing ? _sliceAt(displayMs) : widget.activeSlice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.audioSliceTimeline,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        Semantics(
          label: l10n.audioSliceTimeline,
          child: Listener(
            onPointerCancel: (_) => _endScrubbing(),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: Theme.of(context).colorScheme.primary,
                inactiveTrackColor: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.15),
                thumbColor: Theme.of(context).colorScheme.primary,
                thumbShape: SliderComponentShape.noThumb,
                trackShape: PlayerUniformSliderTrackShape(
                  slices: widget.slices,
                  duration: widget.duration,
                  onlySlices: onlySlices,
                  activeSlice: activeSlice,
                  selectedSlice: widget.selectedSlice,
                  selectedSliceColor: Theme.of(context).colorScheme.secondary,
                ),
              ),
              child: Slider(
                key: const ValueKey('audio-slice-manager-timeline-slider'),
                value: displayMs.toDouble(),
                max: durationMs.toDouble(),
                semanticFormatterCallback: (value) =>
                    formatAudioSliceTime(value.round()),
                onChangeStart: widget.enabled
                    ? (_) {
                        if (!_ownsTrack()) return;
                        ref
                            .read(audioPlayerServiceProvider)
                            .setSliceScrubbing(true);
                        setState(() {
                          _scrubGeneration++;
                          _scrubbing = true;
                          _dragValue = currentMs.toDouble();
                        });
                      }
                    : null,
                onChanged: widget.enabled
                    ? (value) {
                        if (!_ownsTrack()) return;
                        if (!_scrubbing) {
                          _scrubGeneration++;
                          _scrubbing = true;
                          ref
                              .read(audioPlayerServiceProvider)
                              .setSliceScrubbing(true);
                        }
                        setState(() {
                          _dragValue = value;
                        });
                      }
                    : null,
                onChangeEnd: widget.enabled
                    ? (value) => unawaited(_commitScrub(value))
                    : null,
              ),
            ),
          ),
        ),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Icon(Icons.play_arrow, size: 18),
                Text(l10n.audioSlicePosition),
                Text(formatAudioSliceTime(displayMs)),
              ],
            ),
            if (widget.selectedSlice != null)
              Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Icon(Icons.check_circle, size: 18),
                  Text(l10n.audioSliceSelected),
                ],
              ),
          ],
        ),
      ],
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

  void _setEndpoint(TextEditingController controller, int milliseconds) {
    final text = formatAudioSliceTime(milliseconds);
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    final start = parseAudioSliceTime(_start.text);
    final end = parseAudioSliceTime(_end.text);
    setState(() {
      if (start != null &&
          end != null &&
          start < end &&
          end <= widget.duration.inMilliseconds) {
        _range = RangeValues(start.toDouble(), end.toDouble());
      }
      _error = null;
    });
  }

  void _stepEndpoint(TextEditingController controller, int delta) {
    final current = parseAudioSliceTime(controller.text);
    if (current == null) {
      setState(() => _error = S.of(context).audioSliceInvalidTime);
      return;
    }
    _setEndpoint(
      controller,
      (current + delta).clamp(0, widget.duration.inMilliseconds).toInt(),
    );
  }

  void _setCurrentEndpoint(TextEditingController controller) {
    final milliseconds = ref
        .read(audioPlayerServiceProvider)
        .position
        .inMilliseconds;
    _setEndpoint(
      controller,
      milliseconds.clamp(0, widget.duration.inMilliseconds).toInt(),
    );
  }

  Widget _endpointControls(
    String key,
    String endpoint,
    TextEditingController controller,
    bool enabled,
  ) {
    final l10n = S.of(context);
    final actions = <(String, VoidCallback)>[
      (l10n.audioSliceEarlier(0.2), () => _stepEndpoint(controller, -200)),
      (l10n.audioSliceEarlier(1), () => _stepEndpoint(controller, -1000)),
      (l10n.audioSliceEarlier(5), () => _stepEndpoint(controller, -5000)),
      (l10n.audioSliceLater(0.2), () => _stepEndpoint(controller, 200)),
      (l10n.audioSliceLater(1), () => _stepEndpoint(controller, 1000)),
      (l10n.audioSliceLater(5), () => _stepEndpoint(controller, 5000)),
      (l10n.audioSliceSetCurrent, () => _setCurrentEndpoint(controller)),
      (l10n.audioSliceSetZero, () => _setEndpoint(controller, 0)),
      (
        l10n.audioSliceSetEnd,
        () => _setEndpoint(controller, widget.duration.inMilliseconds),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: ValueKey(key),
          controller: controller,
          enabled: enabled,
          decoration: InputDecoration(
            labelText: endpoint,
            hintText: '00:00.000',
          ),
          onChanged: _textChanged,
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (var index = 0; index < actions.length; index++)
              Tooltip(
                message: l10n.audioSliceEndpointAction(
                  endpoint,
                  actions[index].$1,
                ),
                child: OutlinedButton(
                  key: ValueKey('audio-slice-action-$endpoint-$index'),
                  onPressed: enabled ? actions[index].$2 : null,
                  child: Text(actions[index].$1),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _save() async {
    final start = parseAudioSliceTime(_start.text);
    final end = parseAudioSliceTime(_end.text);
    if (start == null || end == null) {
      setState(() => _error = S.of(context).audioSliceInvalidTime);
      return;
    }
    setState(() => _saving = true);
    final edited = AudioSlice(startMs: start, endMs: end);
    final saved = await ref
        .read(audioPlayerServiceProvider)
        .saveSlice(
          trackKey: widget.trackKey,
          slice: edited,
          replacing: widget.slice,
        );
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop(edited);
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
    final loading = ref.watch(isTrackLoadingProvider).valueOrNull ?? false;
    final sameTrack =
        state?.trackKey == widget.trackKey &&
        ref.read(audioPlayerServiceProvider).sliceState.trackKey ==
            widget.trackKey &&
        !state!.isLoading &&
        !loading;
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
            _endpointControls(
              'audio-slice-start-time',
              l10n.audioSliceStartTime,
              _start,
              !_saving && sameTrack,
            ),
            const SizedBox(height: 12),
            _endpointControls(
              'audio-slice-end-time',
              l10n.audioSliceEndTime,
              _end,
              !_saving && sameTrack,
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
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
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
