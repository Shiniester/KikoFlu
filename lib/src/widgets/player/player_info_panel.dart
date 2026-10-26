import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/audio_track.dart';
import '../../providers/audio_provider.dart';
import '../../providers/floating_lyric_provider.dart';
import '../../providers/lyric_provider.dart';
import '../../providers/player_buttons_provider.dart';
import '../../providers/settings_provider.dart';
import '../responsive_dialog.dart';
import '../subtitle_adjustment_dialog.dart';
import 'sleep_timer_dialog.dart';

class PlayerInfoPanel extends ConsumerWidget {
  const PlayerInfoPanel({
    super.key,
    required this.track,
    required this.currentProgress,
    required this.onMarkPressed,
    required this.onDetailPressed,
    required this.onQueuePressed,
    required this.onImmersiveLyrics,
    required this.onLyricSettings,
    this.visibleActionCount = 5,
  });

  final AudioTrack track;
  final String? currentProgress;
  final VoidCallback? onMarkPressed;
  final VoidCallback? onDetailPressed;
  final VoidCallback onQueuePressed;
  final VoidCallback onImmersiveLyrics;
  final VoidCallback onLyricSettings;
  final int visibleActionCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = !Platform.isAndroid && !Platform.isIOS;
    final config = isDesktop
        ? ref.watch(playerButtonsConfigDesktopProvider)
        : ref.watch(playerButtonsConfigMobileProvider);
    final overflow = config
        .getMoreButtons(slotCount: visibleActionCount)
        .where((action) => action != PlayerButtonType.detail)
        .toList(growable: false);
    final keepAwake = ref.watch(keepScreenAwakeProvider);
    final audioState = ref.watch(audioPlayerControllerProvider);
    final lyricState = ref.watch(lyricControllerProvider);
    final timerState = ref.watch(sleepTimerProvider);
    final floatingLyric = ref.watch(floatingLyricEnabledProvider);

    return RepaintBoundary(
      child: BottomSheetMenu(
        key: const PageStorageKey('player-info-panel'),
        children: [
          BottomSheetHeader(
            title: MaterialLocalizations.of(context).moreButtonTooltip,
          ),
          SwitchListTile(
            key: const ValueKey('player-more-keep-awake-card'),
            secondary: Icon(
              keepAwake ? Icons.light_mode : Icons.light_mode_outlined,
            ),
            title: Text(S.of(context).keepScreenAwake),
            value: keepAwake,
            onChanged: (value) =>
                ref.read(keepScreenAwakeProvider.notifier).setEnabled(value),
          ),
          ListTile(
            key: const ValueKey('player-more-fullscreen-card'),
            leading: const Icon(Icons.fullscreen),
            title: Text(S.of(context).fullscreenLyrics),
            onTap: onImmersiveLyrics,
          ),
          for (final action in overflow)
            _PlayerOverflowAction(
              action: action,
              audioState: audioState,
              timelineOffset: lyricState.timelineOffset,
              timerActive: timerState.isActive,
              timerLabel: timerState.isActive ? timerState.formattedTime : null,
              floatingLyric: floatingLyric,
              currentProgress: currentProgress,
              onMarkPressed: onMarkPressed,
              onDetailPressed: onDetailPressed,
              onQueuePressed: onQueuePressed,
            ),
          ListTile(
            key: const ValueKey('player-more-lyric-settings-card'),
            leading: const Icon(Icons.text_fields),
            title: Text(S.of(context).playerLyricViewSettings),
            onTap: onLyricSettings,
          ),
          ListTile(
            key: const ValueKey('player-more-action-detail'),
            leading: const Icon(Icons.info_outline),
            title: Text(S.of(context).viewDetail),
            enabled: onDetailPressed != null,
            onTap: onDetailPressed,
          ),
        ],
      ),
    );
  }
}

class _PlayerOverflowAction extends ConsumerWidget {
  const _PlayerOverflowAction({
    required this.action,
    required this.audioState,
    required this.timelineOffset,
    required this.timerActive,
    required this.timerLabel,
    required this.floatingLyric,
    required this.currentProgress,
    required this.onMarkPressed,
    required this.onDetailPressed,
    required this.onQueuePressed,
  });

  final PlayerButtonType action;
  final AudioPlayerState audioState;
  final Duration timelineOffset;
  final bool timerActive;
  final String? timerLabel;
  final bool floatingLyric;
  final String? currentProgress;
  final VoidCallback? onMarkPressed;
  final VoidCallback? onDetailPressed;
  final VoidCallback onQueuePressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = switch (action) {
      PlayerButtonType.sleepTimer => timerActive,
      PlayerButtonType.speed => audioState.speed != 1,
      PlayerButtonType.repeat => audioState.repeatMode != LoopMode.off,
      PlayerButtonType.mark => currentProgress != null,
      PlayerButtonType.subtitleAdjustment => timelineOffset != Duration.zero,
      PlayerButtonType.floatingLyric => floatingLyric,
      _ => false,
    };
    final icon = switch (action) {
      PlayerButtonType.seekBackward => Icons.replay_10,
      PlayerButtonType.seekForward => Icons.forward_10,
      PlayerButtonType.sleepTimer =>
        timerActive ? Icons.timer : Icons.timer_outlined,
      PlayerButtonType.mark =>
        currentProgress != null ? Icons.bookmark : Icons.bookmark_border,
      PlayerButtonType.volume => Icons.volume_up,
      PlayerButtonType.speed => Icons.speed,
      PlayerButtonType.repeat => switch (audioState.repeatMode) {
        LoopMode.off => Icons.repeat,
        LoopMode.one => Icons.repeat_one,
        LoopMode.all => Icons.repeat_on,
      },
      PlayerButtonType.queue => Icons.queue_music,
      PlayerButtonType.detail => Icons.info_outline,
      PlayerButtonType.subtitleAdjustment => Icons.tune,
      PlayerButtonType.floatingLyric => Icons.picture_in_picture_alt_outlined,
    };
    final label = switch (action) {
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
    final value = switch (action) {
      PlayerButtonType.sleepTimer => timerLabel,
      PlayerButtonType.speed => '${audioState.speed.toStringAsFixed(1)}x',
      PlayerButtonType.volume => '${(audioState.volume * 100).round()}%',
      PlayerButtonType.subtitleAdjustment
          when timelineOffset != Duration.zero =>
        '${timelineOffset.inMilliseconds}ms',
      _ => null,
    };

    return ListTile(
      key: ValueKey('player-more-action-${action.name}'),
      leading: Icon(icon),
      title: Text(label),
      trailing: value != null ? Text(value) : null,
      selected: active,
      enabled: action != PlayerButtonType.mark || onMarkPressed != null,
      onTap: () => _invoke(context, ref),
    );
  }

  Future<void> _invoke(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(audioPlayerControllerProvider.notifier);
    switch (action) {
      case PlayerButtonType.seekBackward:
        await controller.seekBackward(const Duration(seconds: 10));
      case PlayerButtonType.seekForward:
        await controller.seekForward(const Duration(seconds: 10));
      case PlayerButtonType.sleepTimer:
        if (context.mounted) SleepTimerDialog.show(context);
      case PlayerButtonType.mark:
        onMarkPressed?.call();
      case PlayerButtonType.volume:
        if (context.mounted) _showVolumeDialog(context);
      case PlayerButtonType.speed:
        if (context.mounted) _showSpeedDialog(context, ref);
      case PlayerButtonType.repeat:
        final nextMode = switch (audioState.repeatMode) {
          LoopMode.off => LoopMode.one,
          LoopMode.one => LoopMode.all,
          LoopMode.all => LoopMode.off,
        };
        await controller.setRepeatMode(nextMode);
      case PlayerButtonType.queue:
        onQueuePressed();
      case PlayerButtonType.detail:
        onDetailPressed?.call();
      case PlayerButtonType.subtitleAdjustment:
        if (!context.mounted) return;
        showDialog(
          context: context,
          builder: (_) => const SubtitleAdjustmentDialog(),
        );
      case PlayerButtonType.floatingLyric:
        ref.read(floatingLyricEnabledProvider.notifier).toggle();
    }
  }

  void _showSpeedDialog(BuildContext context, WidgetRef ref) {
    var localSpeed = audioState.speed;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
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
                  ref
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

  void _showVolumeDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Consumer(
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
