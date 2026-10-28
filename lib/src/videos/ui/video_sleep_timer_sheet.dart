import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../widgets/responsive_dialog.dart';
import '../video_sleep_timer.dart';

Future<void> showVideoSleepTimerSheet(
  BuildContext context, {
  VideoSleepTimer? timer,
}) => showResponsiveBottomSheet<void>(
  context: context,
  builder: (_) => _VideoSleepTimerSheet(timer: timer ?? VideoSleepTimer.shared),
);

class _VideoSleepTimerSheet extends StatefulWidget {
  const _VideoSleepTimerSheet({required this.timer});
  final VideoSleepTimer timer;

  @override
  State<_VideoSleepTimerSheet> createState() => _VideoSleepTimerSheetState();
}

class _VideoSleepTimerSheetState extends State<_VideoSleepTimerSheet> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final timer = widget.timer;
    return ListenableBuilder(
      listenable: timer,
      builder: (context, _) => BottomSheetMenu(
        children: [
          BottomSheetHeader(
            title: s.videoPlayerSleepTimer,
            subtitle: timer.isActive
                ? timer.waitingForCompletion
                      ? s.finishCurrentTrack
                      : '${s.remainingTime} ${_format(timer.remaining)}'
                : null,
            trailing: [
              IconButton(
                tooltip: s.close,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final minutes in [0, 15, 30, 45, 60])
                  ActionChip(
                    label: Text(
                      minutes == 0
                          ? s.cancelTimer
                          : s.videoPlayerTimerMinutes(minutes),
                    ),
                    onPressed: () => timer.start(Duration(minutes: minutes)),
                  ),
                ActionChip(
                  label: Text(s.videoPlayerTimerCustom),
                  onPressed: () => _showCustomDuration(context),
                ),
              ],
            ),
          ),
          RadioGroup<VideoSleepTimerAction>(
            groupValue: timer.action,
            onChanged: (value) {
              if (value != null) timer.setAction(value);
            },
            child: Column(
              children: [
                for (final action in VideoSleepTimerAction.values)
                  RadioListTile<VideoSleepTimerAction>(
                    title: Text(
                      action == VideoSleepTimerAction.pause
                          ? s.pause
                          : s.videoPlayerExitApp,
                    ),
                    value: action,
                  ),
              ],
            ),
          ),
          SwitchListTile(
            title: Text(s.finishCurrentTrack),
            value: timer.finishCurrentVideo,
            onChanged: timer.setFinishCurrentVideo,
          ),
        ],
      ),
    );
  }

  Future<void> _showCustomDuration(BuildContext context) async {
    final s = S.of(context);
    var hours = 0;
    var minutes = 0;
    final duration = await showDialog<Duration>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.videoPlayerTimerCustom),
        content: SizedBox(
          width: 280,
          height: 160,
          child: Row(
            children: [
              Expanded(
                child: CupertinoPicker(
                  itemExtent: 38,
                  squeeze: 1.25,
                  onSelectedItemChanged: (value) => hours = value,
                  children: List.generate(
                    25,
                    (value) => Center(child: Text('$value')),
                  ),
                ),
              ),
              Text(s.videoPlayerTimerHourUnit),
              Expanded(
                child: CupertinoPicker(
                  itemExtent: 38,
                  squeeze: 1.25,
                  onSelectedItemChanged: (value) => minutes = value,
                  children: List.generate(
                    60,
                    (value) => Center(child: Text('$value')),
                  ),
                ),
              ),
              Text(s.videoPlayerTimerMinuteUnit),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              Duration(hours: hours, minutes: minutes),
            ),
            child: Text(s.confirm),
          ),
        ],
      ),
    );
    if (duration != null) widget.timer.start(duration);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

String _format(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return duration.inHours > 0
      ? '${duration.inHours}:$minutes:$seconds'
      : '$minutes:$seconds';
}
