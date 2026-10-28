import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum VideoSleepTimerAction { pause, exit }

class VideoSleepTimer extends ChangeNotifier {
  VideoSleepTimer({Future<void> Function()? onExit})
    : _onExit = onExit ?? (() async => exit(0));

  static final shared = VideoSleepTimer();

  final Future<void> Function() _onExit;
  Timer? _timer;
  DateTime? _deadline;
  Object? _owner;
  Future<void> Function()? _onPause;
  bool Function()? _isPlaying;
  bool _waitingForCompletion = false;
  bool _actionInProgress = false;
  VideoSleepTimerAction _action = VideoSleepTimerAction.pause;
  bool _finishCurrentVideo = false;

  DateTime? get deadline => _deadline;
  bool get isActive => (_timer?.isActive ?? false) || _waitingForCompletion;
  bool get waitingForCompletion => _waitingForCompletion;
  bool get actionInProgress => _actionInProgress;
  bool owns(Object owner) => identical(_owner, owner);
  VideoSleepTimerAction get action => _action;
  bool get finishCurrentVideo => _finishCurrentVideo;
  Duration get remaining {
    final duration = _deadline?.difference(DateTime.now()) ?? Duration.zero;
    return duration.isNegative ? Duration.zero : duration;
  }

  void attach(
    Object owner, {
    required Future<void> Function() onPause,
    required bool Function() isPlaying,
  }) {
    _owner = owner;
    _onPause = onPause;
    _isPlaying = isPlaying;
  }

  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _onPause = null;
    _isPlaying = null;
  }

  void setAction(VideoSleepTimerAction value) {
    _action = value;
    notifyListeners();
  }

  void setFinishCurrentVideo(bool value) {
    _finishCurrentVideo = value;
    notifyListeners();
  }

  void start(Duration duration) {
    _timer?.cancel();
    _waitingForCompletion = false;
    _deadline = duration > Duration.zero ? DateTime.now().add(duration) : null;
    _timer = duration > Duration.zero ? Timer(duration, _onDeadline) : null;
    notifyListeners();
  }

  void cancel() => start(Duration.zero);

  void _onDeadline() {
    _timer = null;
    _deadline = null;
    if (_finishCurrentVideo && (_isPlaying?.call() ?? false)) {
      _waitingForCompletion = true;
      notifyListeners();
    } else {
      unawaited(_runAction());
    }
  }

  bool handleCompleted(Object owner) {
    if (!_waitingForCompletion || !identical(_owner, owner)) return false;
    _waitingForCompletion = false;
    _actionInProgress = true;
    // Let the player suppress auto-next before pausing emits another snapshot.
    unawaited(Future<void>.microtask(_runAction));
    return true;
  }

  Future<void> _runAction() async {
    final action = _action;
    final pause = _onPause;
    _waitingForCompletion = false;
    _actionInProgress = true;
    notifyListeners();
    try {
      await pause?.call();
      if (action == VideoSleepTimerAction.exit) await _onExit();
    } finally {
      _actionInProgress = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _owner = null;
    _onPause = null;
    _isPlaying = null;
    super.dispose();
  }
}
