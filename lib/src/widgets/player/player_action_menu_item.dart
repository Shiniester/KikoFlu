import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../l10n/app_localizations.dart';
import '../../providers/audio_provider.dart';
import '../../providers/floating_lyric_provider.dart';
import '../../providers/lyric_provider.dart';
import '../../providers/player_buttons_provider.dart';
import '../responsive_dialog.dart';
import '../subtitle_adjustment_dialog.dart';
import 'playback_audio_effects.dart';
import 'playlist_dialog.dart';
import 'sleep_timer_dialog.dart';

enum PlayerActionMenuMode { controls, infoPanel }

class PlayerActionMenuItem extends ConsumerWidget {
  const PlayerActionMenuItem({
    super.key,
    required this.action,
    required this.mode,
    required this.actionContext,
    required this.currentProgress,
    required this.onMarkPressed,
    required this.onDetailPressed,
    required this.onQueuePressed,
  });

  final PlayerButtonType action;
  final PlayerActionMenuMode mode;
  final BuildContext actionContext;
  final String? currentProgress;
  final VoidCallback? onMarkPressed;
  final VoidCallback? onDetailPressed;
  final VoidCallback? onQueuePressed;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final double? speed = action == PlayerButtonType.speed
        ? ref.watch(
            audioPlayerControllerProvider.select((state) => state.speed),
          )
        : null;
    final LoopMode? repeatMode = action == PlayerButtonType.repeat
        ? ref.watch(
            audioPlayerControllerProvider.select((state) => state.repeatMode),
          )
        : null;
    final double? volume = action == PlayerButtonType.volume
        ? ref.watch(
            audioPlayerControllerProvider.select((state) => state.volume),
          )
        : null;
    final timerState = action == PlayerButtonType.sleepTimer
        ? ref.watch(sleepTimerProvider)
        : const SleepTimerState();
    final timelineOffset = action == PlayerButtonType.subtitleAdjustment
        ? ref.watch(
            lyricControllerProvider.select((state) => state.timelineOffset),
          )
        : Duration.zero;
    final floatingLyric = action == PlayerButtonType.floatingLyric
        ? ref.watch(floatingLyricEnabledProvider)
        : false;

    if (mode == PlayerActionMenuMode.controls &&
        action == PlayerButtonType.volume) {
      return _buildVolumeControl(context, ref, volume!);
    }

    final isControls = mode == PlayerActionMenuMode.controls;
    final hasMark = currentProgress != null;
    final isActive = switch (action) {
      PlayerButtonType.sleepTimer => timerState.isActive,
      PlayerButtonType.speed => speed != 1,
      PlayerButtonType.repeat => repeatMode != LoopMode.off,
      PlayerButtonType.mark => hasMark,
      PlayerButtonType.subtitleAdjustment => timelineOffset != Duration.zero,
      PlayerButtonType.floatingLyric => floatingLyric,
      _ => false,
    };
    final colorScheme = Theme.of(context).colorScheme;
    final icon = switch (action) {
      PlayerButtonType.playbackAudioEffects => Icons.equalizer,
      PlayerButtonType.seekBackward => Icons.replay_10,
      PlayerButtonType.seekForward => Icons.forward_10,
      PlayerButtonType.sleepTimer =>
        timerState.isActive ? Icons.timer : Icons.timer_outlined,
      PlayerButtonType.mark => hasMark ? Icons.bookmark : Icons.bookmark_border,
      PlayerButtonType.volume => Icons.volume_up,
      PlayerButtonType.speed => Icons.speed,
      PlayerButtonType.repeat => switch (repeatMode!) {
        LoopMode.off => Icons.repeat,
        LoopMode.one => Icons.repeat_one,
        LoopMode.all => Icons.repeat_on,
      },
      PlayerButtonType.queue => Icons.queue_music,
      PlayerButtonType.detail => Icons.info_outline,
      PlayerButtonType.subtitleAdjustment => Icons.tune,
      PlayerButtonType.floatingLyric =>
        isControls
            ? Icons.picture_in_picture_alt
            : Icons.picture_in_picture_alt_outlined,
    };
    final label = switch (action) {
      PlayerButtonType.playbackAudioEffects =>
        S.of(context).playbackAudioEffects,
      PlayerButtonType.seekBackward => S.of(context).backward10s,
      PlayerButtonType.seekForward => S.of(context).forward10s,
      PlayerButtonType.sleepTimer => S.of(context).sleepTimer,
      PlayerButtonType.mark => S.of(context).addMark,
      PlayerButtonType.volume => S.of(context).volume,
      PlayerButtonType.speed => S.of(context).playbackSpeed,
      PlayerButtonType.repeat => S.of(context).repeatMode,
      PlayerButtonType.queue => S.of(context).playlistTitle,
      PlayerButtonType.detail => S.of(context).viewDetail,
      PlayerButtonType.subtitleAdjustment =>
        S.of(context).subtitleTimingAdjustment,
      PlayerButtonType.floatingLyric => S.of(context).floatingSubtitle,
    };
    final trailing = switch (action) {
      PlayerButtonType.sleepTimer
          when isControls &&
              timerState.isActive &&
              timerState.remainingTime != null =>
        _controlsValue(
          context,
          timerState.formattedTime,
          color: colorScheme.primary,
        ),
      PlayerButtonType.sleepTimer when !isControls && timerState.isActive =>
        Text(timerState.formattedTime),
      PlayerButtonType.speed =>
        isControls
            ? _controlsValue(
                context,
                '${speed!.toStringAsFixed(1)}x',
                color: colorScheme.primary,
              )
            : Text('${speed!.toStringAsFixed(1)}x'),
      PlayerButtonType.repeat when isControls => _controlsValue(
        context,
        switch (repeatMode!) {
          LoopMode.off => S.of(context).repeatOff,
          LoopMode.one => S.of(context).repeatOne,
          LoopMode.all => S.of(context).repeatAll,
        },
        color: isActive ? colorScheme.primary : null,
      ),
      PlayerButtonType.mark when isControls && hasMark => Icon(
        Icons.check_circle,
        color: colorScheme.primary,
        size: 20,
      ),
      PlayerButtonType.volume => Text('${(volume! * 100).round()}%'),
      PlayerButtonType.subtitleAdjustment
          when timelineOffset != Duration.zero =>
        isControls
            ? _controlsValue(
                context,
                '${timelineOffset.inMilliseconds}ms',
                color: colorScheme.primary,
              )
            : Text('${timelineOffset.inMilliseconds}ms'),
      _ => null,
    };

    if (action == PlayerButtonType.floatingLyric && isControls) {
      return ListTile(
        leading: Icon(icon, color: floatingLyric ? colorScheme.primary : null),
        title: Text(label),
        trailing: Transform.scale(
          scale: 0.8,
          alignment: Alignment.centerRight,
          child: Switch(
            value: floatingLyric,
            onChanged: (_) =>
                ref.read(floatingLyricEnabledProvider.notifier).toggle(),
          ),
        ),
        onTap: () => ref.read(floatingLyricEnabledProvider.notifier).toggle(),
      );
    }

    return ListTile(
      key: mode == PlayerActionMenuMode.infoPanel
          ? ValueKey('player-more-action-${action.name}')
          : null,
      leading: Icon(
        icon,
        color: isControls && isActive && action != PlayerButtonType.speed
            ? colorScheme.primary
            : null,
      ),
      title: Text(label),
      trailing: trailing,
      selected: !isControls && isActive,
      enabled:
          isControls ||
          action != PlayerButtonType.mark ||
          onMarkPressed != null,
      onTap: () => _invoke(context, ref, speed, repeatMode),
    );
  }

  Widget _buildVolumeControl(
    BuildContext context,
    WidgetRef ref,
    double volume,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.volume_up),
          title: Text(S.of(context).volume),
          trailing: _controlsValue(
            context,
            '${(volume * 100).round()}%',
            color: colorScheme.primary,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.volume_down,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
              Expanded(
                child: Slider(
                  value: volume,
                  onChanged: (value) => ref
                      .read(audioPlayerControllerProvider.notifier)
                      .setVolume(value),
                ),
              ),
              Icon(
                Icons.volume_up,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Text _controlsValue(BuildContext context, String value, {Color? color}) =>
      Text(
        value,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
      );

  Future<void> _invoke(
    BuildContext context,
    WidgetRef ref,
    double? speed,
    LoopMode? repeatMode,
  ) async {
    final controller = ref.read(audioPlayerControllerProvider.notifier);
    if (mode == PlayerActionMenuMode.controls &&
        action == PlayerButtonType.repeat) {
      controller.setRepeatMode(_nextRepeatMode(repeatMode!));
      Navigator.pop(context);
      return;
    }
    if (mode == PlayerActionMenuMode.controls &&
        action != PlayerButtonType.volume &&
        action != PlayerButtonType.floatingLyric) {
      Navigator.pop(context);
    }

    switch (action) {
      case PlayerButtonType.playbackAudioEffects:
        if (actionContext.mounted) showPlaybackAudioEffects(actionContext);
      case PlayerButtonType.seekBackward:
        if (mode == PlayerActionMenuMode.infoPanel) {
          await controller.seekBackward(const Duration(seconds: 10));
        } else {
          controller.seekBackward(const Duration(seconds: 10));
        }
      case PlayerButtonType.seekForward:
        if (mode == PlayerActionMenuMode.infoPanel) {
          await controller.seekForward(const Duration(seconds: 10));
        } else {
          controller.seekForward(const Duration(seconds: 10));
        }
      case PlayerButtonType.sleepTimer:
        if (actionContext.mounted) SleepTimerDialog.show(actionContext);
      case PlayerButtonType.mark:
        onMarkPressed?.call();
      case PlayerButtonType.volume:
        if (actionContext.mounted) _showVolumeDialog(actionContext);
      case PlayerButtonType.speed:
        if (actionContext.mounted) {
          showPlayerSpeedDialog(actionContext, speed!);
        }
      case PlayerButtonType.repeat:
        await controller.setRepeatMode(_nextRepeatMode(repeatMode!));
      case PlayerButtonType.queue:
        if (onQueuePressed case final callback?) {
          callback();
        } else if (actionContext.mounted) {
          PlaylistDialog.show(actionContext);
        }
      case PlayerButtonType.detail:
        onDetailPressed?.call();
      case PlayerButtonType.subtitleAdjustment:
        if (actionContext.mounted) {
          showDialog<void>(
            context: actionContext,
            builder: (_) => const SubtitleAdjustmentDialog(),
          );
        }
      case PlayerButtonType.floatingLyric:
        ref.read(floatingLyricEnabledProvider.notifier).toggle();
    }
  }

  LoopMode _nextRepeatMode(LoopMode mode) => switch (mode) {
    LoopMode.off => LoopMode.one,
    LoopMode.one => LoopMode.all,
    LoopMode.all => LoopMode.off,
  };

  void _showVolumeDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => Consumer(
        builder: (context, ref, child) {
          final volume = ref.watch(
            audioPlayerControllerProvider.select((state) => state.volume),
          );
          return ResponsiveAlertDialog(
            title: Text(S.of(context).volume),
            content: Slider(
              value: volume,
              onChanged: (value) => ref
                  .read(audioPlayerControllerProvider.notifier)
                  .setVolume(value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(S.of(context).confirm),
              ),
            ],
          );
        },
      ),
    );
  }
}

void showPlayerSpeedDialog(BuildContext context, double currentSpeed) {
  final container = ProviderScope.containerOf(context, listen: false);
  var localSpeed = currentSpeed;
  showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => ResponsiveAlertDialog(
        title: Text(S.of(context).playbackSpeed),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Slider(
              value: localSpeed,
              min: 0.25,
              max: 2.5,
              divisions: 9,
              label: '${localSpeed.toStringAsFixed(1)}x',
              onChanged: (value) {
                setState(() => localSpeed = value);
                container
                    .read(audioPlayerControllerProvider.notifier)
                    .setSpeed(value);
              },
            ),
            Text('${localSpeed.toStringAsFixed(1)}x'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(S.of(context).confirm),
          ),
        ],
      ),
    ),
  );
}
