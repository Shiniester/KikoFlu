import 'playback_audio_effects.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../models/audio_slice.dart';
import '../../providers/audio_provider.dart';
import '../../providers/audio_slice_presentation_provider.dart';
import '../../providers/floating_lyric_provider.dart';
import '../../providers/lyric_provider.dart';
import '../../providers/player_buttons_provider.dart';
import '../../utils/string_utils.dart';
import '../responsive_dialog.dart';
import '../subtitle_adjustment_dialog.dart';
import '../volume_control.dart';
import 'sleep_timer_button.dart';
import 'playlist_dialog.dart';
import 'player_seek_preview.dart';
import 'player_action_menu_item.dart';
import 'player_action_slot.dart';
import 'player_slice_controls.dart';
import 'player_slice_progress.dart';
import '../../../l10n/app_localizations.dart';

export 'player_slice_progress.dart' show PlayerUniformSliderTrackShape;

/// 播放器控制组件
class PlayerControlsWidget extends ConsumerStatefulWidget {
  // Four 48-pixel targets and the 60-pixel play button need 252 pixels.
  static const double compactMinimumWidth = 252;
  static const double compactPreferredWidth = 268;
  static const double primaryRowMinimumWidth = 156;

  final bool isLandscape;
  final bool compactSpacing;
  final bool isSeekingManually;
  final double seekValue;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;
  final ValueChanged<bool>? onSeekInteractionChanged;
  final Duration? seekingPosition;
  final ValueListenable<PlayerSeekPreview?>? seekingPositionListenable;
  final int? workId;
  final String? currentProgress;
  final VoidCallback? onMarkPressed;
  final VoidCallback? onDetailPressed;
  final VoidCallback? onQueuePressed;
  final VoidCallback? onMorePressed;
  final int visibleActionCount;
  final bool showMoreButton;
  final double? additionalActionWidth;
  final double progressTrackTopInset;
  final VoidCallback? debugOnProgressBuild;
  final VoidCallback? debugOnPlayButtonBuild;

  const PlayerControlsWidget({
    super.key,
    required this.isLandscape,
    this.compactSpacing = false,
    required this.isSeekingManually,
    required this.seekValue,
    required this.onSeekChanged,
    required this.onSeekEnd,
    this.onSeekInteractionChanged,
    this.seekingPosition,
    this.seekingPositionListenable,
    this.workId,
    this.currentProgress,
    this.onMarkPressed,
    this.onDetailPressed,
    this.onQueuePressed,
    this.onMorePressed,
    this.visibleActionCount = 5,
    this.showMoreButton = false,
    this.additionalActionWidth,
    this.progressTrackTopInset = PlayerProgressSection.centeredTrackTopInset,
    this.debugOnProgressBuild,
    this.debugOnPlayButtonBuild,
  });

  @override
  ConsumerState<PlayerControlsWidget> createState() =>
      _PlayerControlsWidgetState();
}

class _PlayerControlsWidgetState extends ConsumerState<PlayerControlsWidget> {
  void _showMoreMenu(BuildContext context, WidgetRef ref) {
    final isDesktop = !Platform.isAndroid && !Platform.isIOS;
    final config = isDesktop
        ? ref.read(playerButtonsConfigDesktopProvider)
        : ref.read(playerButtonsConfigMobileProvider);
    final moreButtons = config.getMoreButtons(
      slotCount: widget.visibleActionCount,
    );

    showResponsiveBottomSheet(
      context: context,
      builder: (context) => BottomSheetMenu(
        header: BottomSheetHeader(
          title: MaterialLocalizations.of(context).moreButtonTooltip,
        ),
        children: [
          ...moreButtons.map(
            (buttonType) => PlayerActionMenuItem(
              action: buttonType,
              mode: PlayerActionMenuMode.controls,
              actionContext: this.context,
              currentProgress: widget.currentProgress,
              onMarkPressed: widget.onMarkPressed,
              onDetailPressed: widget.onDetailPressed,
              onQueuePressed: widget.onQueuePressed,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildButton(
    BuildContext context,
    WidgetRef ref,
    PlayerButtonType buttonType,
    bool isLandscape,
    ({double volume, double speed, LoopMode repeatMode}) audioState,
  ) {
    final iconSize = isLandscape ? 24.0 : null;
    Widget action(Widget child, {String? label}) =>
        PlayerActionSlot(isLandscape: isLandscape, label: label, child: child);

    switch (buttonType) {
      case PlayerButtonType.playbackAudioEffects:
        return action(
          IconButton(
            tooltip: S.of(context).playbackAudioEffects,
            icon: const Icon(Icons.equalizer),
            iconSize: iconSize,
            onPressed: () => showPlaybackAudioEffects(context),
          ),
        );
      case PlayerButtonType.seekBackward:
        return action(
          IconButton(
            onPressed: () {
              ref
                  .read(audioPlayerControllerProvider.notifier)
                  .seekBackward(const Duration(seconds: 10));
            },
            icon: const Icon(Icons.replay_10),
            iconSize: iconSize,
          ),
        );
      case PlayerButtonType.seekForward:
        return action(
          IconButton(
            onPressed: () {
              ref
                  .read(audioPlayerControllerProvider.notifier)
                  .seekForward(const Duration(seconds: 10));
            },
            icon: const Icon(Icons.forward_10),
            iconSize: iconSize,
          ),
        );
      case PlayerButtonType.sleepTimer:
        return SleepTimerButton(iconSize: iconSize);
      case PlayerButtonType.volume:
        return action(
          VolumeControl(
            volume: audioState.volume,
            onVolumeChanged: (value) {
              ref.read(audioPlayerControllerProvider.notifier).setVolume(value);
            },
            iconSize: iconSize,
          ),
        );
      case PlayerButtonType.speed:
        return action(
          IconButton(
            onPressed: () {
              showPlayerSpeedDialog(context, audioState.speed);
            },
            icon: Icon(
              Icons.speed,
              color: audioState.speed != 1.0
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            iconSize: iconSize,
          ),
          label: audioState.speed != 1.0
              ? '${audioState.speed.toStringAsFixed(1)}x'
              : null,
        );
      case PlayerButtonType.repeat:
        return action(
          IconButton(
            onPressed: () {
              final nextMode = switch (audioState.repeatMode) {
                LoopMode.off => LoopMode.one,
                LoopMode.one => LoopMode.all,
                LoopMode.all => LoopMode.off,
              };
              ref
                  .read(audioPlayerControllerProvider.notifier)
                  .setRepeatMode(nextMode);
            },
            icon: Icon(
              switch (audioState.repeatMode) {
                LoopMode.off => Icons.repeat,
                LoopMode.one => Icons.repeat_one,
                LoopMode.all => Icons.repeat_on,
              },
              color: audioState.repeatMode != LoopMode.off
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            iconSize: iconSize,
          ),
        );
      case PlayerButtonType.queue:
        return action(
          IconButton(
            tooltip: S.of(context).playlistTitle,
            onPressed:
                widget.onQueuePressed ?? () => PlaylistDialog.show(context),
            icon: const Icon(Icons.queue_music),
            iconSize: iconSize,
          ),
        );
      case PlayerButtonType.mark:
        return action(
          IconButton(
            onPressed: widget.onMarkPressed,
            icon: Icon(
              widget.currentProgress != null
                  ? Icons.bookmark
                  : Icons.bookmark_border,
              color: widget.currentProgress != null
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            iconSize: iconSize,
          ),
        );
      case PlayerButtonType.detail:
        return action(
          IconButton(
            onPressed: widget.onDetailPressed,
            icon: const Icon(Icons.info_outline),
            iconSize: iconSize,
          ),
        );
      case PlayerButtonType.subtitleAdjustment:
        final lyricState = ref.watch(lyricControllerProvider);
        final hasOffset = lyricState.timelineOffset != Duration.zero;
        return action(
          IconButton(
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => const SubtitleAdjustmentDialog(),
              );
            },
            icon: Badge(
              isLabelVisible: hasOffset,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: const Icon(Icons.tune),
            ),
          ),
        );
      case PlayerButtonType.floatingLyric:
        final isEnabled = ref.watch(floatingLyricEnabledProvider);
        return action(
          IconButton(
            onPressed: () {
              ref.read(floatingLyricEnabledProvider.notifier).toggle();
            },
            icon: Icon(
              isEnabled
                  ? Icons.picture_in_picture_alt
                  : Icons.picture_in_picture_alt_outlined,
              color: isEnabled ? Theme.of(context).colorScheme.primary : null,
            ),
            iconSize: iconSize,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconSize = widget.isLandscape ? 38.0 : 40.0;
    final playButtonSize = widget.isLandscape ? 62.0 : 60.0;
    final playIconSize = widget.isLandscape ? 31.0 : 30.0;
    final audioState = ref.watch(
      audioPlayerControllerProvider.select(
        (state) => (
          volume: state.volume,
          speed: state.speed,
          repeatMode: state.repeatMode,
        ),
      ),
    );

    return Column(
      children: [
        // Progress slider
        PlayerProgressSection(
          trackTopInset: widget.progressTrackTopInset,
          isSeekingManually: widget.isSeekingManually,
          seekValue: widget.seekValue,
          onSeekChanged: widget.onSeekChanged,
          onSeekEnd: widget.onSeekEnd,
          onInteractionChanged: widget.onSeekInteractionChanged,
          seekingPositionListenable: widget.seekingPositionListenable,
          debugOnBuild: widget.debugOnProgressBuild,
        ),
        SizedBox(
          height: widget.compactSpacing ? 0 : (widget.isLandscape ? 18 : 10),
        ),
        // Main controls
        LayoutBuilder(
          builder: (context, constraints) {
            final compactPadding =
                constraints.maxWidth <
                    PlayerControlsWidget.compactPreferredWidth
                ? EdgeInsets.zero
                : null;
            const sliceCutButton = PlayerSliceCutButton();
            final skipPreviousButton = IconButton(
              key: const ValueKey('player-skip-previous-button'),
              onPressed: ref.watch(canSkipPreviousProvider)
                  ? () {
                      ref
                          .read(audioPlayerControllerProvider.notifier)
                          .skipToPrevious();
                    }
                  : null,
              icon: const Icon(Icons.skip_previous),
              iconSize: iconSize,
              padding: compactPadding,
            );
            final playButton = PlayerPlayPauseButton(
              buttonSize: constraints.maxWidth
                  .clamp(48.0, playButtonSize)
                  .toDouble(),
              iconSize: playIconSize,
              debugOnBuild: widget.debugOnPlayButtonBuild,
            );
            final skipNextButton = IconButton(
              key: const ValueKey('player-skip-next-button'),
              onPressed: ref.watch(canSkipNextProvider)
                  ? () {
                      ref
                          .read(audioPlayerControllerProvider.notifier)
                          .skipToNext();
                    }
                  : null,
              icon: const Icon(Icons.skip_next),
              iconSize: iconSize,
              padding: compactPadding,
            );
            const sliceManagerButton = PlayerSliceManagerButton();
            if (constraints.maxWidth <
                PlayerControlsWidget.compactMinimumWidth) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [skipPreviousButton, playButton, skipNextButton],
                  ),
                  const Wrap(
                    alignment: WrapAlignment.center,
                    children: [sliceCutButton, sliceManagerButton],
                  ),
                ],
              );
            }
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                sliceCutButton,
                skipPreviousButton,
                playButton,
                skipNextButton,
                sliceManagerButton,
              ],
            );
          },
        ),
        SizedBox(
          height: widget.compactSpacing ? 0 : (widget.isLandscape ? 16 : 10),
        ),
        // Additional controls
        Consumer(
          builder: (context, ref, child) {
            final isDesktop = !Platform.isAndroid && !Platform.isIOS;
            final config = isDesktop
                ? ref.watch(playerButtonsConfigDesktopProvider)
                : ref.watch(playerButtonsConfigMobileProvider);
            final visibleButtons = config.getVisibleButtons(
              slotCount: widget.visibleActionCount,
            );

            final actionChildren = <Widget>[
              ...visibleButtons.map(
                (type) => _buildButton(
                  context,
                  ref,
                  type,
                  widget.isLandscape,
                  audioState,
                ),
              ),
              if (widget.showMoreButton)
                PlayerActionSlot(
                  isLandscape: widget.isLandscape,
                  child: IconButton(
                    onPressed: () {
                      if (widget.onMorePressed != null) {
                        widget.onMorePressed!();
                      } else {
                        _showMoreMenu(context, ref);
                      }
                    },
                    icon: Builder(
                      builder: (context) {
                        final moreButtons = config.getMoreButtons(
                          slotCount: widget.visibleActionCount,
                        );
                        final hasSpeedInMore = moreButtons.contains(
                          PlayerButtonType.speed,
                        );
                        final hasRepeatInMore = moreButtons.contains(
                          PlayerButtonType.repeat,
                        );
                        final hasSleepTimerInMore = moreButtons.contains(
                          PlayerButtonType.sleepTimer,
                        );
                        final hasSubtitleAdjustmentInMore = moreButtons
                            .contains(PlayerButtonType.subtitleAdjustment);
                        final hasFloatingLyricInMore = moreButtons.contains(
                          PlayerButtonType.floatingLyric,
                        );
                        final timerState = ref.watch(sleepTimerProvider);
                        final lyricState = ref.watch(lyricControllerProvider);
                        final isFloatingLyricEnabled = ref.watch(
                          floatingLyricEnabledProvider,
                        );

                        final shouldShowBadge =
                            (hasSpeedInMore && audioState.speed != 1.0) ||
                            (hasRepeatInMore &&
                                audioState.repeatMode != LoopMode.off) ||
                            (hasSleepTimerInMore && timerState.isActive) ||
                            (hasSubtitleAdjustmentInMore &&
                                lyricState.timelineOffset != Duration.zero) ||
                            (hasFloatingLyricInMore && isFloatingLyricEnabled);

                        return Badge(
                          isLabelVisible: shouldShowBadge,
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary,
                          child: const Icon(Icons.more_horiz),
                        );
                      },
                    ),
                    iconSize: widget.isLandscape ? 24 : null,
                  ),
                ),
            ];
            if (widget.isLandscape && widget.additionalActionWidth == null) {
              return LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: constraints.maxWidth),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: actionChildren,
                    ),
                  ),
                ),
              );
            }
            final actions = SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.start,
                children: actionChildren,
              ),
            );
            final width = widget.additionalActionWidth;
            if (width == null) return actions;
            return LayoutBuilder(
              builder: (context, constraints) {
                final edgeOffset = ((width - constraints.maxWidth) / 2)
                    .clamp(0.0, double.infinity)
                    .toDouble();
                final lastIndex = actionChildren.length - 1;
                return SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.start,
                    children: [
                      for (
                        var index = 0;
                        index < actionChildren.length;
                        index++
                      )
                        Transform.translate(
                          offset: Offset(
                            lastIndex == 0
                                ? 0
                                : edgeOffset * (index * 2 / lastIndex - 1),
                            0,
                          ),
                          child: actionChildren[index],
                        ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }
}

class PlayerProgressSection extends ConsumerWidget {
  static const sliderHeight = 32.0;
  static const trackHeight = 4.0;
  static const centeredTrackTopInset = (sliderHeight - trackHeight) / 2;
  static const compactTrackTopInset = 6.0;

  const PlayerProgressSection({
    super.key,
    required this.isSeekingManually,
    required this.seekValue,
    required this.onSeekChanged,
    required this.onSeekEnd,
    this.onInteractionChanged,
    this.seekingPositionListenable,
    this.debugOnBuild,
    this.trackTopInset = centeredTrackTopInset,
  });

  final bool isSeekingManually;
  final double seekValue;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;
  final ValueChanged<bool>? onInteractionChanged;
  final ValueListenable<PlayerSeekPreview?>? seekingPositionListenable;
  final VoidCallback? debugOnBuild;
  final double trackTopInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    debugOnBuild?.call();
    final pos = ref.watch(positionProvider).value ?? Duration.zero;
    final dur = ref.watch(durationProvider).value ?? Duration.zero;
    final isTrackLoading =
        ref.watch(isTrackLoadingProvider).valueOrNull ?? false;
    final slices =
        ref.watch(audioSliceStateProvider).valueOrNull ??
        const AudioSliceState();
    final selectedSlice = ref.watch(selectedAudioSliceProvider);
    final seekingPositionListenable = this.seekingPositionListenable;
    if (seekingPositionListenable != null) {
      return ValueListenableBuilder<PlayerSeekPreview?>(
        valueListenable: seekingPositionListenable,
        builder: (context, seekPreview, _) => _buildProgressSection(
          context,
          ref,
          slices: slices,
          selectedSlice: selectedSlice,
          pos: pos,
          dur: dur,
          isTrackLoading: isTrackLoading,
          isSeekingManually: seekPreview?.isSeekingManually ?? false,
          seekValue: seekPreview?.seekValue ?? 0,
          displayPos: seekPreview?.position ?? pos,
        ),
      );
    }
    final displayPos = isSeekingManually
        ? Duration(milliseconds: (seekValue * dur.inMilliseconds).round())
        : pos;
    return _buildProgressSection(
      context,
      ref,
      slices: slices,
      selectedSlice: selectedSlice,
      pos: pos,
      dur: dur,
      isTrackLoading: isTrackLoading,
      isSeekingManually: isSeekingManually,
      seekValue: seekValue,
      displayPos: displayPos,
    );
  }

  Widget _buildProgressSection(
    BuildContext context,
    WidgetRef ref, {
    required AudioSliceState slices,
    required AudioSlice? selectedSlice,
    required Duration pos,
    required Duration dur,
    required bool isTrackLoading,
    required bool isSeekingManually,
    required double seekValue,
    required Duration displayPos,
  }) {
    final sliderValue =
        (isSeekingManually
                ? seekValue
                : dur.inMilliseconds > 0
                ? pos.inMilliseconds / dur.inMilliseconds
                : 0.0)
            .clamp(0.0, 1.0)
            .toDouble();
    final colorScheme = Theme.of(context).colorScheme;
    final sliceColor = PlayerUniformSliderTrackShape.sliceColorFor(colorScheme);
    final thumbColor =
        dur.inMilliseconds > 0 &&
            PlayerUniformSliderTrackShape.isPositionInSlice(
              sliderValue * dur.inMilliseconds,
              slices.slices,
            )
        ? sliceColor
        : colorScheme.primary;
    return IgnorePointer(
      key: const ValueKey('player-progress-loading-guard'),
      ignoring: isTrackLoading,
      child: RepaintBoundary(
        child: Column(
          children: [
            GestureDetector(
              onLongPressStart: (details) {
                if (slices.trackKey == null) return;
                final box = context.findRenderObject() as RenderBox;
                const thumbRadius = PlayerUniformSliderTrackShape.thumbRadius;
                final trackWidth = box.size.width - thumbRadius * 2;
                final fraction =
                    ((details.localPosition.dx - thumbRadius) / trackWidth)
                        .clamp(0.0, 1.0);
                final time =
                    (Directionality.of(context) == TextDirection.rtl
                        ? 1 - fraction
                        : fraction) *
                    dur.inMilliseconds;
                AudioSlice? selected;
                for (final slice in slices.slices) {
                  if (time >= slice.startMs && time < slice.endMs) {
                    selected = slice;
                    break;
                  }
                }
                showPlayerSliceManager(
                  context,
                  initialSlice: selected,
                  trackKey: slices.trackKey,
                );
              },
              child: Listener(
                key: const ValueKey('player-progress-gesture-target'),
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => onInteractionChanged?.call(true),
                onPointerUp: (_) => onInteractionChanged?.call(false),
                onPointerCancel: (_) {
                  ref.read(audioPlayerServiceProvider).setSliceScrubbing(false);
                  onInteractionChanged?.call(false);
                },
                child: SizedBox(
                  height: sliderHeight,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: colorScheme.primary,
                      thumbColor: thumbColor,
                      inactiveTrackColor: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.15),
                      trackHeight: trackHeight,
                      trackShape: PlayerUniformSliderTrackShape(
                        verticalOffset: trackTopInset - centeredTrackTopInset,
                        slices: slices.slices,
                        duration: dur,
                        pendingStartMs: slices.pendingStartMs,
                        onlySlices: slices.onlySlices,
                        selectedSlice: selectedSlice,
                        sliceColor: sliceColor,
                      ),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius:
                            PlayerUniformSliderTrackShape.thumbRadius,
                        disabledThumbRadius:
                            PlayerUniformSliderTrackShape.thumbRadius,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: PlayerUniformSliderTrackShape.thumbRadius,
                      ),
                    ),
                    child: Slider(
                      key: const ValueKey('player-progress-slider'),
                      value: sliderValue,
                      onChanged: onSeekChanged,
                      onChangeStart: (_) => ref
                          .read(audioPlayerServiceProvider)
                          .setSliceScrubbing(true),
                      onChangeEnd: (value) {
                        onSeekEnd(value);
                        ref
                            .read(audioPlayerServiceProvider)
                            .setSliceScrubbing(false);
                      },
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.zero,
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      formatDuration(displayPos, padHours: false),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      formatDuration(dur, padHours: false),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlayerPlayPauseButton extends ConsumerWidget {
  const PlayerPlayPauseButton({
    super.key,
    required this.buttonSize,
    required this.iconSize,
    this.debugOnBuild,
  });

  final double buttonSize;
  final double iconSize;
  final VoidCallback? debugOnBuild;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    debugOnBuild?.call();
    final isPlaying = ref.watch(isPlayingProvider);
    return RepaintBoundary(
      child: Container(
        width: buttonSize,
        height: buttonSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).colorScheme.primary,
        ),
        child: IconButton(
          onPressed: () {
            final controller = ref.read(audioPlayerControllerProvider.notifier);
            if (isPlaying) {
              controller.pause();
            } else {
              controller.play();
            }
          },
          icon: Icon(
            isPlaying ? Icons.pause : Icons.play_arrow,
            color: Theme.of(context).colorScheme.onPrimary,
          ),
          iconSize: iconSize,
        ),
      ),
    );
  }
}
