import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/responsive_dialog.dart';
import '../video_playback_settings.dart';
import '../video_player_platform.dart';

class VideoPlaybackSettingsRoute extends StatefulWidget {
  const VideoPlaybackSettingsRoute({super.key, this.platformFactory});

  final VideoPlayerPlatform Function()? platformFactory;

  @override
  State<VideoPlaybackSettingsRoute> createState() =>
      _VideoPlaybackSettingsRouteState();
}

class _VideoPlaybackSettingsRouteState
    extends State<VideoPlaybackSettingsRoute> {
  final _settings = VideoPlaybackSettings();
  late final VideoPlayerPlatform _platform;
  late final Future<void> _initialization;

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _platform = widget.platformFactory?.call() ?? VideoPlayerPlatform();
    _initialization = _initialize();
  }

  Future<void> _initialize() async {
    await _settings.initialize();
    try {
      await _platform.initialize();
    } catch (_) {
      // Playback preferences remain available when a native bridge is absent.
    }
  }

  Future<bool> _setSystemBrightnessMode(bool enabled) async {
    var applied = await _platform.setSystemBrightnessMode(enabled);
    if (!applied && enabled) {
      await _platform.requestSystemBrightnessPermission();
      applied = await _platform.setSystemBrightnessMode(true);
    }
    return applied;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _initialization,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return Scaffold(
          appBar: AppBar(title: Text(S.of(context).videoPlayerSettings)),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      return VideoPlaybackSettingsScreen(
        settings: _settings,
        supportsAutomaticPictureInPicture:
            _isMobile && _platform.supportsPictureInPicture,
        supportsBatteryStatus: _platform.supportsBatteryStatus,
        supportsGravityRotation:
            defaultTargetPlatform == TargetPlatform.android,
        supportsFullscreenOrientation: _isMobile,
        supportsSystemBrightness: _platform.supportsSystemBrightness,
        onSystemBrightnessChanged: _setSystemBrightnessMode,
      );
    },
  );

  @override
  void dispose() {
    _settings.dispose();
    unawaited(_platform.dispose());
    super.dispose();
  }
}

class VideoPlaybackSettingsScreen extends StatelessWidget {
  const VideoPlaybackSettingsScreen({
    super.key,
    required this.settings,
    this.supportsAutomaticPictureInPicture = false,
    this.supportsBatteryStatus = false,
    this.supportsGravityRotation = false,
    this.supportsFullscreenOrientation = true,
    this.supportsSystemBrightness = false,
    this.onSystemBrightnessChanged,
    this.hasRelatedVideos = false,
  });

  final VideoPlaybackSettings settings;
  final bool supportsAutomaticPictureInPicture;
  final bool supportsBatteryStatus;
  final bool supportsGravityRotation;
  final bool supportsFullscreenOrientation;
  final bool supportsSystemBrightness;
  final Future<bool> Function(bool value)? onSystemBrightnessChanged;
  final bool hasRelatedVideos;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.videoPlayerSettings)),
      body: AnimatedBuilder(
        animation: settings,
        builder: (context, _) => ListView(
          children: [
            SwitchListTile(
              title: Text(s.videoPlayerAutoPlay),
              value: settings.autoPlay,
              onChanged: settings.setAutoPlay,
            ),
            SwitchListTile(
              title: Text(s.videoPlayerAutoFullscreen),
              value: settings.autoFullscreen,
              onChanged: settings.setAutoFullscreen,
            ),
            SwitchListTile(
              title: Text(s.videoPlayerAutoExitFullscreen),
              value: settings.autoExitFullscreen,
              onChanged: settings.setAutoExitFullscreen,
            ),
            if (supportsAutomaticPictureInPicture)
              SwitchListTile(
                title: Text(s.videoPlayerAutoPip),
                value: settings.autoPictureInPicture,
                onChanged: settings.setAutoPictureInPicture,
              ),
            SwitchListTile(
              title: Text(s.videoPlayerShowFullscreenLockButton),
              value: settings.showFullscreenLockButton,
              onChanged: settings.setShowFullscreenLockButton,
            ),
            SwitchListTile(
              title: Text(s.videoPlayerShowFullscreenScreenshotButton),
              value: settings.showFullscreenScreenshotButton,
              onChanged: settings.setShowFullscreenScreenshotButton,
            ),
            ListTile(
              title: Text(s.videoPlayerDoubleTapSeek),
              trailing: Switch(
                value: settings.enableDoubleTapSeek,
                onChanged: settings.setEnableDoubleTapSeek,
              ),
            ),
            ListTile(
              title: Text(s.videoPlayerDoubleTapSeekDuration),
              subtitle: Text('${settings.doubleTapSeekSeconds} s'),
              onTap: () => _select<int>(
                context,
                s.videoPlayerDoubleTapSeekDuration,
                const [5, 10, 15],
                settings.doubleTapSeekSeconds,
                (value) async {
                  await settings.setDoubleTapSeekSeconds(value);
                },
                (value) => '$value s',
              ),
            ),
            ListTile(
              title: Text(s.videoPlayerLongPressSpeed),
              subtitle: Text('${settings.longPressRate}×'),
              onTap: () => _select<double>(
                context,
                s.videoPlayerLongPressSpeed,
                const [1.5, 2, 2.5, 3, 4],
                settings.longPressRate,
                (value) async {
                  await settings.setLongPressRate(value);
                },
                (value) => '$value×',
              ),
            ),
            SwitchListTile(
              title: Text(s.videoPlayerDynamicLongPressSpeed),
              value: settings.dynamicLongPressRate,
              onChanged: (value) async {
                await settings.setDynamicLongPressRate(value);
              },
            ),
            SwitchListTile(
              title: Text(s.videoPlayerSideSwipeAdjust),
              value: settings.enableSideSwipeAdjust,
              onChanged: settings.setEnableSideSwipeAdjust,
            ),
            if (supportsSystemBrightness && onSystemBrightnessChanged != null)
              SwitchListTile(
                title: Text(s.videoPlayerSystemBrightness),
                value: settings.systemBrightness,
                onChanged: (value) async {
                  final applied = await onSystemBrightnessChanged!(value);
                  if (!context.mounted) return;
                  if (applied) {
                    await settings.setSystemBrightness(value);
                  } else if (value) {
                    SnackBarUtil.showFromSnackBar(
                      context,
                      SnackBar(
                        content: Text(s.videoPlayerSystemBrightnessPermission),
                      ),
                    );
                  }
                },
              ),
            SwitchListTile(
              title: Text(s.videoPlayerFullscreenGesture),
              value: settings.enableFullscreenGesture,
              onChanged: settings.setEnableFullscreenGesture,
            ),
            SwitchListTile(
              title: Text(s.videoPlayerReverseFullscreenGesture),
              value: settings.reverseFullscreenGesture,
              onChanged: settings.setReverseFullscreenGesture,
            ),
            SwitchListTile(
              title: Text(s.videoPlayerKeyboardControl),
              value: settings.keyboardControl,
              onChanged: settings.setKeyboardControl,
            ),
            SwitchListTile(
              title: Text(s.videoPlayerRelativeSwipeSeek),
              value: settings.relativeSwipeSeek,
              onChanged: settings.setRelativeSwipeSeek,
            ),
            ListTile(
              title: Text(s.videoPlayerSwipeSeekDuration),
              subtitle: Text(
                '${settings.swipeSeekDuration}${settings.relativeSwipeSeek ? '%' : ' s'}',
              ),
              onTap: () => _select<int>(
                context,
                s.videoPlayerSwipeSeekDuration,
                const [25, 50, 90, 100],
                settings.swipeSeekDuration,
                settings.setSwipeSeekDuration,
                (value) => '$value${settings.relativeSwipeSeek ? '%' : ' s'}',
              ),
            ),
            ListTile(
              title: Text(s.videoPlayerDefaultSpeed),
              subtitle: Text('${settings.playbackRate}×'),
              onTap: () => _select<double>(
                context,
                s.videoPlayerDefaultSpeed,
                settings.speedList,
                settings.playbackRate,
                (value) async {
                  await settings.setPlaybackRate(value);
                },
                (value) => '$value×',
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                s.videoPlayerSpeedList,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            RadioGroup<double>(
              groupValue: settings.playbackRate,
              onChanged: (value) {
                if (value != null) unawaited(settings.setPlaybackRate(value));
              },
              child: Column(
                children: [
                  for (final speed in settings.speedList)
                    RadioListTile<double>(
                      value: speed,
                      title: Text('$speed×'),
                      subtitle: speed == settings.playbackRate
                          ? Text(s.videoPlayerDefaultSpeed)
                          : null,
                      secondary: IconButton(
                        tooltip: s.delete,
                        onPressed:
                            settings.speedList.length <= 1 ||
                                speed == settings.playbackRate
                            ? null
                            : () => unawaited(settings.removeSpeed(speed)),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton.icon(
                onPressed: () => _addSpeed(context),
                icon: const Icon(Icons.add),
                label: Text(s.videoPlayerAddSpeed),
              ),
            ),
            ListTile(
              title: Text(s.videoPlayerAspectRatio),
              subtitle: Text(_fitLabel(s, settings.fit)),
              onTap: () => _select<VideoPlayerFit>(
                context,
                s.videoPlayerAspectRatio,
                VideoPlayerFit.values,
                settings.fit,
                (value) async {
                  await settings.setFit(value);
                },
                (value) => _fitLabel(s, value),
              ),
            ),
            if (supportsFullscreenOrientation)
              ListTile(
                title: Text(s.videoPlayerFullscreenOrientation),
                subtitle: Text(
                  _orientationLabel(s, settings.fullscreenOrientation),
                ),
                onTap: () => _select<VideoFullscreenOrientation>(
                  context,
                  s.videoPlayerFullscreenOrientation,
                  [
                    for (final value in VideoFullscreenOrientation.values)
                      if (supportsGravityRotation ||
                          value != VideoFullscreenOrientation.gravity)
                        value,
                  ],
                  settings.fullscreenOrientation,
                  settings.setFullscreenOrientation,
                  (value) => _orientationLabel(s, value),
                ),
              ),
            ListTile(
              title: Text(s.videoPlayerBottomProgressMode),
              subtitle: Text(_progressLabel(s, settings.bottomProgressMode)),
              onTap: () => _select<VideoBottomProgressMode>(
                context,
                s.videoPlayerBottomProgressMode,
                VideoBottomProgressMode.values,
                settings.bottomProgressMode,
                settings.setBottomProgressMode,
                (value) => _progressLabel(s, value),
              ),
            ),
            SwitchListTile(
              title: Text(s.videoPlayerExpandVertical),
              value: settings.expandVerticalVideo,
              onChanged: settings.setExpandVerticalVideo,
            ),
            ListTile(
              title: Text(s.repeatMode),
              subtitle: Text(_repeatLabel(s, settings.repeatMode)),
              onTap: () => _select<VideoPlayerRepeatMode>(
                context,
                s.repeatMode,
                [
                  VideoPlayerRepeatMode.once,
                  VideoPlayerRepeatMode.single,
                  if (hasRelatedVideos) VideoPlayerRepeatMode.related,
                ],
                settings.repeatMode,
                settings.setRepeatMode,
                (value) => _repeatLabel(s, value),
              ),
            ),
            SwitchListTile(
              title: Text(s.videoPlayerBackgroundPlayback),
              value: settings.backgroundPlayback,
              onChanged: (value) async {
                await settings.setBackgroundPlayback(value);
              },
            ),
            SwitchListTile(
              title: Text(s.videoPlayerExtendedControlTime),
              value: settings.extendedControlTime,
              onChanged: (value) async {
                await settings.setExtendedControlTime(value);
              },
            ),
            if (supportsBatteryStatus)
              SwitchListTile(
                title: Text(s.videoPlayerShowFullscreenBattery),
                value: settings.showFullscreenBattery,
                onChanged: settings.setShowFullscreenBattery,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                s.videoPlayerSubtitleStyle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            SwitchListTile(
              title: Text(s.videoPlayerSubtitleTrack),
              value: settings.subtitlesEnabled,
              onChanged: settings.setSubtitlesEnabled,
            ),
            ListTile(
              title: Text(s.videoPlayerSubtitleFontSize),
              subtitle: Slider(
                min: 16,
                max: 48,
                divisions: 16,
                value: settings.subtitleFontSize,
                label: settings.subtitleFontSize.round().toString(),
                onChanged: (value) =>
                    unawaited(settings.setSubtitleFontSize(value)),
              ),
            ),
            SwitchListTile(
              title: Text(s.videoPlayerSubtitleBackground),
              value: settings.subtitleBackground,
              onChanged: (value) async {
                await settings.setSubtitleBackground(value);
              },
            ),
            ListTile(
              title: Text(s.videoPlayerSubtitleOffset),
              subtitle: Slider(
                min: -5,
                max: 5,
                divisions: 100,
                value: settings.subtitleOffsetSeconds,
                label: '${settings.subtitleOffsetSeconds.toStringAsFixed(1)} s',
                onChanged: (value) =>
                    unawaited(settings.setSubtitleOffsetSeconds(value)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fitLabel(S s, VideoPlayerFit fit) => switch (fit) {
    VideoPlayerFit.contain => s.videoPlayerFitContain,
    VideoPlayerFit.fill => s.videoPlayerFitFill,
    VideoPlayerFit.cover => s.videoPlayerFitCover,
    VideoPlayerFit.width => s.videoPlayerFitWidth,
    VideoPlayerFit.height => s.videoPlayerFitHeight,
    VideoPlayerFit.original => s.videoPlayerFitOriginal,
    VideoPlayerFit.scaleDown => s.videoPlayerFitScaleDown,
    VideoPlayerFit.fourThree => s.videoPlayerFitFourThree,
    VideoPlayerFit.sixteenNine => s.videoPlayerFitSixteenNine,
  };

  String _orientationLabel(S s, VideoFullscreenOrientation orientation) =>
      switch (orientation) {
        VideoFullscreenOrientation.auto => s.videoPlayerOrientationAuto,
        VideoFullscreenOrientation.none => s.videoPlayerOrientationNone,
        VideoFullscreenOrientation.vertical => s.videoPlayerOrientationPortrait,
        VideoFullscreenOrientation.horizontal =>
          s.videoPlayerOrientationLandscape,
        VideoFullscreenOrientation.ratio => s.videoPlayerOrientationRatio,
        VideoFullscreenOrientation.gravity => s.videoPlayerOrientationGravity,
      };

  String _progressLabel(S s, VideoBottomProgressMode mode) => switch (mode) {
    VideoBottomProgressMode.always => s.videoPlayerBottomProgressAlways,
    VideoBottomProgressMode.never => s.videoPlayerBottomProgressNever,
    VideoBottomProgressMode.fullscreenOnly =>
      s.videoPlayerBottomProgressFullscreenOnly,
    VideoBottomProgressMode.inlineOnly => s.videoPlayerBottomProgressInlineOnly,
  };

  String _repeatLabel(S s, VideoPlayerRepeatMode mode) => switch (mode) {
    VideoPlayerRepeatMode.once => s.videoPlayerRepeatOnce,
    VideoPlayerRepeatMode.single => s.videoPlayerRepeatSingle,
    VideoPlayerRepeatMode.related => s.videoPlayerRepeatRelated,
  };

  Future<void> _select<T>(
    BuildContext context,
    String title,
    List<T> values,
    T selected,
    ValueChangedAsync<T> onSelected,
    String Function(T) label,
  ) async {
    final value = await showResponsiveBottomSheet<T>(
      context: context,
      builder: (context) => BottomSheetMenu(
        children: [
          BottomSheetHeader(title: title),
          for (final item in values)
            ListTile(
              leading: Icon(
                item == selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              title: Text(label(item)),
              onTap: () => Navigator.of(context).pop(item),
            ),
        ],
      ),
    );
    if (value != null) await onSelected(value);
  }

  Future<void> _addSpeed(BuildContext context) async {
    final s = S.of(context);
    final formKey = GlobalKey<FormState>();
    var input = '';
    final value = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(s.videoPlayerAddSpeed),
        content: Form(
          key: formKey,
          child: TextFormField(
            key: const ValueKey('video-player-add-speed-input'),
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(suffixText: '×'),
            validator: (value) {
              final speed = double.tryParse(value ?? '');
              if (speed == null ||
                  !speed.isFinite ||
                  speed <= 0 ||
                  settings.speedList.contains(speed)) {
                return s.videoPlayerInvalidSpeed;
              }
              return null;
            },
            onSaved: (value) => input = value ?? '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              formKey.currentState!.save();
              Navigator.pop(dialogContext, double.parse(input));
            },
            child: Text(s.add),
          ),
        ],
      ),
    );
    if (value != null) await settings.addSpeed(value);
  }
}

typedef ValueChangedAsync<T> = Future<void> Function(T value);
