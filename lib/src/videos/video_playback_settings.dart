import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'video_super_resolution.dart';

enum VideoPlayerFit {
  contain,
  fill,
  cover,
  width,
  height,
  original,
  scaleDown,
  fourThree,
  sixteenNine,
}

enum VideoFullscreenOrientation {
  auto,
  none,
  vertical,
  horizontal,
  ratio,
  gravity,
}

enum VideoBottomProgressMode { always, never, fullscreenOnly, inlineOnly }

enum VideoPlayerRepeatMode { once, single, related }

/// User preferences shared by the inline and fullscreen player surfaces.
class VideoPlaybackSettings extends ChangeNotifier {
  VideoPlaybackSettings({SharedPreferences? preferences})
    : _providedPreferences = preferences;

  static const _prefix = 'video_player_v1_';
  static const defaultSpeedList = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0];

  final SharedPreferences? _providedPreferences;
  SharedPreferences? _preferences;
  Future<void>? _initializing;
  Future<void> _writeTail = Future<void>.value();
  bool _disposed = false;

  int doubleTapSeekSeconds = 10;
  double longPressRate = 3;
  bool dynamicLongPressRate = false;
  double playbackRate = 1;
  List<double> speedList = List<double>.of(defaultSpeedList);
  bool autoPlay = false;
  bool autoFullscreen = false;
  bool autoExitFullscreen = true;
  bool autoPictureInPicture = false;
  bool enableDoubleTapSeek = true;
  bool enableSideSwipeAdjust = true;
  bool systemBrightness = false;
  bool enableFullscreenGesture = true;
  bool relativeSwipeSeek = false;
  int swipeSeekDuration = 90;
  bool expandVerticalVideo = false;
  bool showFullscreenLockButton = true;
  bool showFullscreenScreenshotButton = true;
  bool keyboardControl = true;
  bool reverseFullscreenGesture = false;
  VideoPlayerFit fit = VideoPlayerFit.contain;
  VideoFullscreenOrientation fullscreenOrientation =
      VideoFullscreenOrientation.auto;
  VideoBottomProgressMode bottomProgressMode = VideoBottomProgressMode.always;
  VideoPlayerRepeatMode repeatMode = VideoPlayerRepeatMode.once;
  bool backgroundPlayback = false;
  bool extendedControlTime = false;
  bool showFullscreenBattery = true;
  bool subtitlesEnabled = true;
  bool flipHorizontal = false;
  bool flipVertical = false;
  VideoSuperResolution superResolution = VideoSuperResolution.off;
  double subtitleFontSize = 32;
  bool subtitleBackground = true;
  double subtitleOffsetSeconds = 0;

  Future<void> initialize() {
    if (_preferences != null) return Future.value();
    return _initializing ??= _load().whenComplete(() => _initializing = null);
  }

  Future<void> reload() async {
    await initialize();
    await _writeTail;
    if (_disposed) return;
    await _load();
  }

  Future<void> _load() async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    _preferences = preferences;
    doubleTapSeekSeconds =
        preferences.getInt('${_prefix}double_tap_seek') ?? 10;
    longPressRate = preferences.getDouble('${_prefix}long_press_rate') ?? 3;
    dynamicLongPressRate =
        preferences.getBool('${_prefix}dynamic_long_press') ?? false;
    playbackRate = preferences.getDouble('${_prefix}playback_rate') ?? 1;
    final savedSpeedList = preferences.getStringList('${_prefix}speed_list');
    speedList =
        (savedSpeedList == null
                  ? List<double>.of(defaultSpeedList)
                  : savedSpeedList
                        .map(double.tryParse)
                        .whereType<double>()
                        .where((value) => value.isFinite && value > 0)
                        .toSet()
                        .toList()
              ..sort())
            .toList();
    if (playbackRate.isFinite &&
        playbackRate > 0 &&
        !speedList.contains(playbackRate)) {
      speedList.add(playbackRate);
      speedList.sort();
    }
    autoPlay = preferences.getBool('${_prefix}auto_play') ?? false;
    autoFullscreen = preferences.getBool('${_prefix}auto_fullscreen') ?? false;
    autoExitFullscreen =
        preferences.getBool('${_prefix}auto_exit_fullscreen') ?? true;
    autoPictureInPicture = preferences.getBool('${_prefix}auto_pip') ?? false;
    enableDoubleTapSeek =
        preferences.getBool('${_prefix}double_tap_enabled') ?? true;
    enableSideSwipeAdjust =
        preferences.getBool('${_prefix}side_swipe_enabled') ?? true;
    systemBrightness =
        preferences.getBool('${_prefix}system_brightness') ?? false;
    enableFullscreenGesture =
        preferences.getBool('${_prefix}fullscreen_gesture_enabled') ?? true;
    relativeSwipeSeek =
        preferences.getBool('${_prefix}relative_swipe_seek') ?? false;
    swipeSeekDuration =
        preferences.getInt('${_prefix}swipe_seek_duration') ?? 90;
    expandVerticalVideo =
        preferences.getBool('${_prefix}vertical_expand') ?? false;
    showFullscreenLockButton =
        preferences.getBool('${_prefix}fullscreen_lock_button') ?? true;
    showFullscreenScreenshotButton =
        preferences.getBool('${_prefix}fullscreen_screenshot_button') ?? true;
    keyboardControl = preferences.getBool('${_prefix}keyboard_control') ?? true;
    reverseFullscreenGesture =
        preferences.getBool('${_prefix}reverse_fullscreen_gesture') ?? false;
    fit =
        VideoPlayerFit.values[(preferences.getInt('${_prefix}fit') ?? 0)
            .clamp(0, VideoPlayerFit.values.length - 1)
            .toInt()];
    fullscreenOrientation =
        VideoFullscreenOrientation.values[(preferences.getInt(
                  '${_prefix}fullscreen_orientation',
                ) ??
                0)
            .clamp(0, VideoFullscreenOrientation.values.length - 1)
            .toInt()];
    bottomProgressMode =
        VideoBottomProgressMode.values[(preferences.getInt(
                  '${_prefix}bottom_progress_mode',
                ) ??
                0)
            .clamp(0, VideoBottomProgressMode.values.length - 1)
            .toInt()];
    repeatMode =
        VideoPlayerRepeatMode.values[(preferences.getInt(
                  '${_prefix}repeat_mode',
                ) ??
                0)
            .clamp(0, VideoPlayerRepeatMode.values.length - 1)
            .toInt()];
    backgroundPlayback =
        preferences.getBool('${_prefix}background_playback') ?? false;
    extendedControlTime =
        preferences.getBool('${_prefix}extended_controls') ?? false;
    showFullscreenBattery =
        preferences.getBool('${_prefix}show_fullscreen_battery') ?? true;
    subtitlesEnabled =
        preferences.getBool('${_prefix}subtitles_enabled') ?? true;
    subtitleFontSize = preferences.getDouble('${_prefix}subtitle_size') ?? 32;
    subtitleBackground =
        preferences.getBool('${_prefix}subtitle_background') ?? true;
    subtitleOffsetSeconds =
        preferences.getDouble('${_prefix}subtitle_offset') ?? 0;
    _notify();
  }

  Future<void> setDoubleTapSeekSeconds(int value) => _set(
    '${_prefix}double_tap_seek',
    value,
    () => doubleTapSeekSeconds = value,
  );

  Future<void> setLongPressRate(double value) =>
      _set('${_prefix}long_press_rate', value, () => longPressRate = value);

  Future<void> setDynamicLongPressRate(bool value) => _set(
    '${_prefix}dynamic_long_press',
    value,
    () => dynamicLongPressRate = value,
  );

  Future<void> setPlaybackRate(double value) =>
      _set('${_prefix}playback_rate', value, () => playbackRate = value);

  Future<void> setSpeedList(List<double> value) {
    final speeds =
        value.where((speed) => speed.isFinite && speed > 0).toSet().toList()
          ..sort();
    if (speeds.isEmpty) return Future.value();
    if (!speeds.contains(playbackRate)) {
      speeds.add(playbackRate);
      speeds.sort();
    }
    return _set(
      '${_prefix}speed_list',
      speeds.map((speed) => speed.toString()).toList(),
      () => speedList = speeds,
    );
  }

  Future<void> addSpeed(double value) {
    if (!value.isFinite || value <= 0 || speedList.contains(value)) {
      return Future.value();
    }
    return setSpeedList([...speedList, value]);
  }

  Future<void> removeSpeed(double value) {
    if (speedList.length <= 1 || value == playbackRate) {
      return Future.value();
    }
    return setSpeedList(speedList.where((speed) => speed != value).toList());
  }

  double get defaultSpeed => playbackRate;

  Future<void> setAutoPlay(bool value) =>
      _set('${_prefix}auto_play', value, () => autoPlay = value);

  Future<void> setAutoFullscreen(bool value) =>
      _set('${_prefix}auto_fullscreen', value, () => autoFullscreen = value);

  Future<void> setAutoExitFullscreen(bool value) => _set(
    '${_prefix}auto_exit_fullscreen',
    value,
    () => autoExitFullscreen = value,
  );

  Future<void> setAutoPictureInPicture(bool value) =>
      _set('${_prefix}auto_pip', value, () => autoPictureInPicture = value);

  Future<void> setEnableDoubleTapSeek(bool value) => _set(
    '${_prefix}double_tap_enabled',
    value,
    () => enableDoubleTapSeek = value,
  );

  Future<void> setEnableSideSwipeAdjust(bool value) => _set(
    '${_prefix}side_swipe_enabled',
    value,
    () => enableSideSwipeAdjust = value,
  );

  Future<void> setSystemBrightness(bool value) => _set(
    '${_prefix}system_brightness',
    value,
    () => systemBrightness = value,
  );

  Future<void> setEnableFullscreenGesture(bool value) => _set(
    '${_prefix}fullscreen_gesture_enabled',
    value,
    () => enableFullscreenGesture = value,
  );

  Future<void> setRelativeSwipeSeek(bool value) => _set(
    '${_prefix}relative_swipe_seek',
    value,
    () => relativeSwipeSeek = value,
  );

  Future<void> setSwipeSeekDuration(int value) => _set(
    '${_prefix}swipe_seek_duration',
    value,
    () => swipeSeekDuration = value,
  );

  Future<void> setExpandVerticalVideo(bool value) => _set(
    '${_prefix}vertical_expand',
    value,
    () => expandVerticalVideo = value,
  );

  Future<void> setShowFullscreenLockButton(bool value) => _set(
    '${_prefix}fullscreen_lock_button',
    value,
    () => showFullscreenLockButton = value,
  );

  Future<void> setShowFullscreenScreenshotButton(bool value) => _set(
    '${_prefix}fullscreen_screenshot_button',
    value,
    () => showFullscreenScreenshotButton = value,
  );

  Future<void> setKeyboardControl(bool value) =>
      _set('${_prefix}keyboard_control', value, () => keyboardControl = value);

  Future<void> setReverseFullscreenGesture(bool value) => _set(
    '${_prefix}reverse_fullscreen_gesture',
    value,
    () => reverseFullscreenGesture = value,
  );

  Future<void> setFullscreenOrientation(VideoFullscreenOrientation value) =>
      _set(
        '${_prefix}fullscreen_orientation',
        value.index,
        () => fullscreenOrientation = value,
      );

  Future<void> setBottomProgressMode(VideoBottomProgressMode value) => _set(
    '${_prefix}bottom_progress_mode',
    value.index,
    () => bottomProgressMode = value,
  );

  Future<void> setFit(VideoPlayerFit value) =>
      _set('${_prefix}fit', value.index, () => fit = value);

  bool get loopSingle => repeatMode == VideoPlayerRepeatMode.single;

  bool get autoPlayRelated => repeatMode == VideoPlayerRepeatMode.related;

  Future<void> setLoopSingle(bool value) => setRepeatMode(
    value ? VideoPlayerRepeatMode.single : VideoPlayerRepeatMode.once,
  );

  Future<void> setRepeatMode(VideoPlayerRepeatMode value) =>
      _set('${_prefix}repeat_mode', value.index, () => repeatMode = value);

  Future<void> setBackgroundPlayback(bool value) => _set(
    '${_prefix}background_playback',
    value,
    () => backgroundPlayback = value,
  );

  Future<void> setExtendedControlTime(bool value) => _set(
    '${_prefix}extended_controls',
    value,
    () => extendedControlTime = value,
  );

  Future<void> setShowFullscreenBattery(bool value) => _set(
    '${_prefix}show_fullscreen_battery',
    value,
    () => showFullscreenBattery = value,
  );

  Future<void> setSubtitlesEnabled(bool value) => _set(
    '${_prefix}subtitles_enabled',
    value,
    () => subtitlesEnabled = value,
  );

  Future<void> setFlipHorizontal(bool value) =>
      _setTemporary(() => flipHorizontal = value);

  Future<void> setFlipVertical(bool value) =>
      _setTemporary(() => flipVertical = value);

  Future<void> setSuperResolution(VideoSuperResolution value) =>
      _setTemporary(() => superResolution = value);

  Future<void> setSubtitleFontSize(double value) =>
      _set('${_prefix}subtitle_size', value, () => subtitleFontSize = value);

  Future<void> setSubtitleBackground(bool value) => _set(
    '${_prefix}subtitle_background',
    value,
    () => subtitleBackground = value,
  );

  Future<void> setSubtitleOffsetSeconds(double value) => _set(
    '${_prefix}subtitle_offset',
    value,
    () => subtitleOffsetSeconds = value,
  );

  Future<void> _set(String key, Object value, VoidCallback update) async {
    await initialize();
    update();
    final preferences = _preferences!;
    final write = _writeTail.then((_) async {
      if (value is bool) {
        await preferences.setBool(key, value);
      } else if (value is int) {
        await preferences.setInt(key, value);
      } else if (value is double) {
        await preferences.setDouble(key, value);
      } else if (value is List<String>) {
        await preferences.setStringList(key, value);
      }
    });
    _writeTail = write.catchError((_) {});
    await write;
    _notify();
  }

  Future<void> _setTemporary(VoidCallback update) async {
    await initialize();
    update();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
