import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/audio_provider.dart';
import 'player_action_slot.dart';
import 'sleep_timer_dialog.dart';

/// 定时器按钮/指示器
class SleepTimerButton extends ConsumerWidget {
  final double? iconSize;

  const SleepTimerButton({super.key, this.iconSize});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timerState = ref.watch(sleepTimerProvider);
    return PlayerActionSlot(
      isLandscape: iconSize != null,
      label: timerState.isActive && timerState.remainingTime != null
          ? timerState.formattedTime
          : null,
      child: IconButton(
        onPressed: () => SleepTimerDialog.show(context),
        icon: Icon(
          !timerState.isActive
              ? Icons.timer_outlined
              : timerState.waitingForTrackEnd
              ? Icons.hourglass_bottom
              : Icons.timer,
          color: timerState.isActive
              ? Theme.of(context).colorScheme.primary
              : null,
        ),
        iconSize: iconSize,
      ),
    );
  }
}
