import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../utils/desktop_window_options.dart';

/// Owns temporary platform state for one video screen.
class VideoPlayerPlatform {
  VideoPlayerPlatform({
    MethodChannel? channel,
    MethodChannel? pictureInPictureChannel,
    WindowManager? desktopWindow,
    TargetPlatform? platform,
  }) : _channel =
           channel ??
           const MethodChannel('com.meteor.kikoeruflutter/video_player'),
       _pipChannel =
           pictureInPictureChannel ??
           const MethodChannel(
             'com.meteor.kikoeruflutter/video_picture_in_picture',
           ),
       _window = desktopWindow ?? windowManager,
       _platform = platform ?? defaultTargetPlatform;

  final MethodChannel _channel;
  final MethodChannel _pipChannel;
  final WindowManager _window;
  final TargetPlatform _platform;
  final ValueNotifier<bool> _pictureInPicture = ValueNotifier(false);
  bool _brightnessSupported = false;
  bool _pipSupported = false;
  bool _disposed = false;
  Future<bool>? _entering;
  Future<void>? _exiting;
  _DesktopWindowState? _desktopState;
  bool? _originalFullscreen;
  bool? _originalAlwaysOnTop;
  VideoController? _pipController;
  final List<StreamSubscription<dynamic>> _pipStateSubscriptions = [];
  static final Map<String, VideoPlayerPlatform> _owners = {};
  static Future<void> _platformOperations = Future<void>.value();
  bool _releasing = false;
  bool get _ownsPlatform => _owners[_channel.name] == this;

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _platformOperations.then((_) => operation());
    _platformOperations = result.then(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  ValueListenable<bool> get pictureInPicture => _pictureInPicture;
  bool get supportsBrightness => _brightnessSupported;
  bool get supportsPictureInPicture => _pipSupported;
  bool get supportsSystemBrightness =>
      !kIsWeb && _platform == TargetPlatform.android;
  bool get supportsBatteryStatus =>
      !kIsWeb &&
      (_platform == TargetPlatform.android || _platform == TargetPlatform.iOS);

  Future<({int level, bool charging})?> getBatteryStatus() async {
    if (!supportsBatteryStatus || !_ownsPlatform || _disposed || _releasing) {
      return null;
    }
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>(
        'getBatteryStatus',
      );
      final level = status?['level'];
      final charging = status?['charging'];
      if (level is! int || level < 0 || level > 100 || charging is! bool) {
        return null;
      }
      return (level: level, charging: charging);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  bool get _desktop =>
      !kIsWeb &&
      <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ].contains(_platform);
  MethodChannel get _nativePipChannel =>
      _platform == TargetPlatform.iOS ? _pipChannel : _channel;

  Future<void> initialize() => _serialize(() async {
    if (_disposed || _ownsPlatform) return;
    final previous = _owners[_channel.name];
    if (previous != null) await previous._releasePlatform();
    _owners[_channel.name] = this;
    _nativePipChannel.setMethodCallHandler((call) async {
      if (_disposed) return;
      switch (call.method) {
        case 'pictureInPictureChanged':
          _pictureInPicture.value = call.arguments == true;
        case 'setPlaying':
          final player = _pipController?.player;
          if (player != null) {
            if (call.arguments == true) {
              await player.play();
            } else {
              await player.pause();
            }
          }
        case 'skipByInterval':
          final player = _pipController?.player;
          if (player != null && call.arguments is num) {
            final state = player.state;
            final milliseconds =
                state.position.inMilliseconds +
                ((call.arguments as num).toDouble() * 1000).round();
            await player.seek(
              Duration(
                milliseconds: milliseconds.clamp(
                  0,
                  state.duration.inMilliseconds > 0
                      ? state.duration.inMilliseconds
                      : milliseconds.abs(),
                ),
              ),
            );
          }
      }
    });
    if (_desktop) {
      _pipSupported = true;
      return;
    }
    try {
      final capabilities = await _channel.invokeMapMethod<String, dynamic>(
        'initialize',
      );
      _brightnessSupported = capabilities?['brightness'] == true;
      _pipSupported = capabilities?['pictureInPicture'] == true;
    } on MissingPluginException {
      _brightnessSupported = false;
      _pipSupported = false;
    } on PlatformException {
      _pipSupported = false;
    }
    if (_platform == TargetPlatform.iOS) {
      try {
        _pipSupported =
            await _pipChannel.invokeMethod<bool>('isSupported') ?? false;
      } on MissingPluginException {
        _pipSupported = false;
      } on PlatformException {
        _pipSupported = false;
      }
    }
  });

  Future<double> getBrightness() async {
    if (!_brightnessSupported || !_ownsPlatform) return 0.5;
    final value = await _channel.invokeMethod<double>('getBrightness');
    return (value ?? 0.5).clamp(0.0, 1.0);
  }

  Future<void> setBrightness(double value) async {
    if (!_brightnessSupported || _disposed || _releasing || !_ownsPlatform) {
      return;
    }
    await _channel.invokeMethod<void>('setBrightness', {
      'value': value.clamp(0.0, 1.0),
    });
  }

  Future<void> resetBrightness() async {
    if (_brightnessSupported && _ownsPlatform) {
      await _channel.invokeMethod<void>('resetBrightness');
    }
  }

  Future<void> setKeepScreenOn(bool enabled) async {
    if (_disposed || _releasing || !_ownsPlatform) return;
    try {
      await _channel.invokeMethod<void>('setKeepScreenOn', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // Web has no native screen-awake bridge.
    }
  }

  Future<void> setBackgroundPlayback(bool enabled) async {
    if (!_ownsPlatform || _disposed) return;
    if (_platform == TargetPlatform.android) {
      await _channel.invokeMethod<void>('setBackgroundPlayback', {
        'enabled': enabled,
      });
    }
  }

  Future<bool> getSystemBrightnessMode() async =>
      supportsSystemBrightness &&
      _ownsPlatform &&
      (await _channel.invokeMethod<bool>('getSystemBrightnessMode') ?? false);

  Future<bool> setSystemBrightnessMode(bool enabled) async {
    if (!supportsSystemBrightness || !_ownsPlatform || _disposed) return false;
    return await _channel.invokeMethod<bool>('setSystemBrightnessMode', {
          'enabled': enabled,
        }) ??
        false;
  }

  Future<void> requestSystemBrightnessPermission() async {
    if (supportsSystemBrightness && _ownsPlatform && !_disposed) {
      await _channel.invokeMethod<void>('requestSystemBrightnessPermission');
    }
  }

  Future<void> setGravityOrientation(bool enabled) async {
    if (_platform == TargetPlatform.android && _ownsPlatform && !_disposed) {
      await _channel.invokeMethod<void>('setGravityOrientation', {
        'enabled': enabled,
      });
    }
  }

  Future<void> setFullscreenStatusBarHidden(bool hidden) {
    if (kIsWeb ||
        _platform != TargetPlatform.android ||
        !_ownsPlatform ||
        _disposed ||
        _releasing) {
      return Future<void>.value();
    }
    return _serialize(() async {
      if (!_ownsPlatform || _disposed || _releasing) return;
      try {
        await _channel.invokeMethod<void>('setFullscreenStatusBarHidden', {
          'hidden': hidden,
        });
      } on MissingPluginException {
        // Missing system UI support must not block fullscreen playback.
      } on PlatformException {
        // System UI visibility must not block fullscreen playback.
      }
    });
  }

  Future<void> setNativeFullscreen(bool enabled) {
    if (!_desktop || !_ownsPlatform || _disposed || _releasing) {
      return Future<void>.value();
    }
    return _serialize(() async {
      if (!_ownsPlatform || _disposed || _releasing) return;
      if (!enabled && _originalFullscreen == null) return;
      // PiP restores its window snapshot before fullscreen changes that state.
      await _exitPictureInPicture();
      if (enabled) {
        _originalFullscreen ??= await _window.isFullScreen();
        try {
          await _setDesktopFullscreen(true);
        } on PlatformException {
          await _restoreNativeFullscreen();
          rethrow;
        }
      } else {
        await _restoreNativeFullscreen();
      }
    });
  }

  Future<bool> isAlwaysOnTop() {
    if (!_desktop || !_ownsPlatform || _disposed || _releasing) {
      return Future<bool>.value(false);
    }
    return _serialize(() async {
      if (!_ownsPlatform || _disposed || _releasing) return false;
      return _window.isAlwaysOnTop();
    });
  }

  Future<void> setAlwaysOnTop(bool enabled) {
    if (!_desktop || !_ownsPlatform || _disposed || _releasing) {
      return Future<void>.value();
    }
    return _serialize(() async {
      if (!_ownsPlatform || _disposed || _releasing) return;
      await _exitPictureInPicture();
      _originalAlwaysOnTop ??= await _window.isAlwaysOnTop();
      await _window.setAlwaysOnTop(enabled);
    });
  }

  Future<void> _restoreAlwaysOnTop() async {
    final original = _originalAlwaysOnTop;
    if (original == null) return;
    await _window.setAlwaysOnTop(original);
    _originalAlwaysOnTop = null;
  }

  Future<void> _restoreNativeFullscreen() async {
    final original = _originalFullscreen;
    if (original == null) return;
    await _setDesktopFullscreen(original);
    _originalFullscreen = null;
  }

  Future<void> _setDesktopFullscreen(bool enabled) async {
    if (_platform != TargetPlatform.macOS) {
      await _window.setFullScreen(enabled);
      return;
    }
    if (await _window.isFullScreen() == enabled) return;
    final transition = _FullscreenTransition(enabled);
    _window.addListener(transition);
    try {
      await _window.setFullScreen(enabled);
      await transition.completed.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      throw PlatformException(
        code: 'fullscreen_transition_timeout',
        message: 'The desktop window did not finish changing fullscreen state.',
      );
    } finally {
      _window.removeListener(transition);
    }
  }

  Future<void> attachVideoController(VideoController controller) async {
    if (_desktop || kIsWeb) return;
    if (!_ownsPlatform ||
        _disposed ||
        _releasing ||
        _pipController == controller) {
      return;
    }
    await _stopPipState();
    if (!_ownsPlatform || _disposed || _releasing) return;
    _pipController = controller;
    final player = controller.player;
    _pipStateSubscriptions.addAll([
      player.stream.position.listen((_) => _sendPipState()),
      player.stream.duration.listen((_) => _sendPipState()),
      player.stream.playing.listen((_) => _sendPipState()),
      player.stream.rate.listen((_) => _sendPipState()),
    ]);
    await _sendPipState();
  }

  Future<void> setAutoPictureInPicture(
    bool enabled, {
    double aspectRatio = 16 / 9,
  }) async {
    if (!_ownsPlatform ||
        _disposed ||
        _releasing ||
        !_pipSupported ||
        _desktop) {
      return;
    }
    final args = <String, dynamic>{
      'enabled': enabled,
      'aspectRatio': aspectRatio,
    };
    if (_platform == TargetPlatform.iOS && enabled) {
      final controller = _pipController;
      if (controller == null) return;
      try {
        await controller.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 5),
        );
      } on TimeoutException {
        return;
      }
      if (_disposed || _releasing || !_ownsPlatform) return;
      args['handle'] = (await controller.player.handle).toString();
    }
    await _nativePipChannel.invokeMethod<void>('setAutoPictureInPicture', args);
    await _sendPipState();
  }

  Future<bool> enterPictureInPicture(
    VideoController controller, {
    required double aspectRatio,
  }) async {
    if (_disposed || _releasing || !_ownsPlatform || !_pipSupported) {
      return false;
    }
    if (_pictureInPicture.value) return true;
    return _entering ??=
        (_desktop
                ? _serialize(() async {
                    if (!_ownsPlatform || _disposed || _releasing) return false;
                    return _enter(controller, aspectRatio);
                  })
                : _enter(controller, aspectRatio))
            .whenComplete(() => _entering = null);
  }

  Future<bool> _enter(VideoController controller, double aspectRatio) async {
    final ratio = aspectRatio.isFinite && aspectRatio > 0
        ? aspectRatio
        : 16 / 9;
    try {
      if (_desktop) {
        final fullscreen = await _window.isFullScreen();
        var maximized = await _window.isMaximized();
        final alwaysOnTop = await _window.isAlwaysOnTop();
        _desktopState = _DesktopWindowState(
          bounds: await _window.getBounds(),
          fullscreen: fullscreen,
          maximized: maximized,
          alwaysOnTop: alwaysOnTop,
        );
        if (fullscreen) {
          await _setDesktopFullscreen(false);
          maximized = await _window.isMaximized();
        }
        if (maximized) await _window.unmaximize();
        _desktopState = _DesktopWindowState(
          bounds: await _window.getBounds(),
          fullscreen: fullscreen,
          maximized: maximized,
          alwaysOnTop: alwaysOnTop,
        );
        await _window.setMinimumSize(const Size(160, 90));
        await _window.setSize(Size(480, (480 / ratio).clamp(135.0, 600.0)));
        await _window.setAlwaysOnTop(true);
        if (_disposed || _releasing) {
          await _restoreDesktop();
          return false;
        }
        _pictureInPicture.value = true;
        return true;
      }
      final args = <String, dynamic>{'aspectRatio': ratio};
      if (_platform == TargetPlatform.android) {
        await attachVideoController(controller);
      }
      if (_platform == TargetPlatform.iOS) {
        await controller.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 5),
        );
        if (_disposed || _releasing) return false;
        args['handle'] = (await controller.player.handle).toString();
        await attachVideoController(controller);
      }
      if (_disposed || _releasing) return false;
      final entering = _nativePipChannel.invokeMethod<bool>(
        'enterPictureInPicture',
        args,
      );
      if (_platform == TargetPlatform.iOS) await _sendPipState();
      final entered = await entering ?? false;
      return entered;
    } on PlatformException {
      if (_desktopState != null) await _restoreDesktop();
      return false;
    } on MissingPluginException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  Future<void> _sendPipState() async {
    final state = _pipController?.player.state;
    if (_disposed || _releasing || !_ownsPlatform || state == null) return;
    try {
      await _nativePipChannel.invokeMethod<void>('updateState', {
        'position': state.position.inMicroseconds / 1000000,
        'duration': state.duration.inMicroseconds / 1000000,
        'playing': state.playing,
        'rate': state.rate,
      });
    } on PlatformException catch (error) {
      debugPrint('Failed to update video PiP state: $error');
    } on MissingPluginException {
      // A detached engine no longer has a PiP output.
    }
  }

  Future<void> _stopPipState() async {
    _pipController = null;
    final subscriptions = List<StreamSubscription<dynamic>>.of(
      _pipStateSubscriptions,
    );
    _pipStateSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  Future<void> exitPictureInPicture() {
    if (!_ownsPlatform) return Future<void>.value();
    return _exiting ??=
        (_desktop
                ? _serialize(() async {
                    if (_ownsPlatform) await _exitPictureInPicture();
                  })
                : _exitPictureInPicture())
            .whenComplete(() => _exiting = null);
  }

  Future<void> _exitPictureInPicture() async {
    if (_desktop) {
      await _restoreDesktop();
      if (!_disposed) _pictureInPicture.value = false;
    } else {
      try {
        await _nativePipChannel.invokeMethod<void>('exitPictureInPicture');
      } on MissingPluginException {
        // Unsupported hosts have nothing to restore.
      }
    }
  }

  Future<void> _restoreDesktop() async {
    final state = _desktopState;
    if (state == null) return;
    // Keep the snapshot until all restoration succeeds, allowing a retry.
    await _window.setAlwaysOnTop(state.alwaysOnTop);
    await _window.setMinimumSize(
      createDesktopWindowOptions(
        isWindows: _platform == TargetPlatform.windows,
      ).minimumSize!,
    );
    await _window.setBounds(state.bounds);
    if (state.maximized) await _window.maximize();
    if (state.fullscreen) await _setDesktopFullscreen(true);
    _desktopState = null;
  }

  Future<void> _releasePlatform() async {
    _releasing = true;
    try {
      if (_desktop) {
        await _exitPictureInPicture();
      } else {
        await exitPictureInPicture();
        await _entering;
        await exitPictureInPicture();
      }
      await _restoreNativeFullscreen();
      await _restoreAlwaysOnTop();
    } finally {
      try {
        await _stopPipState();
        await resetBrightness();
      } finally {
        try {
          await _channel.invokeMethod<void>('dispose');
        } on MissingPluginException {
          // No platform state exists on unsupported hosts.
        } finally {
          _nativePipChannel.setMethodCallHandler(null);
          _pictureInPicture.value = false;
          _releasing = false;
        }
      }
    }
  }

  Future<void> dispose() {
    if (_disposed) return Future<void>.value();
    _disposed = true;
    if (!_ownsPlatform) {
      final stopping = _stopPipState();
      _pictureInPicture.dispose();
      return stopping;
    }
    return _serialize(() async {
      try {
        if (_ownsPlatform) {
          await _releasePlatform();
        } else {
          await _stopPipState();
        }
      } finally {
        if (_ownsPlatform) _owners.remove(_channel.name);
        _pictureInPicture.dispose();
      }
    });
  }
}

class _FullscreenTransition with WindowListener {
  _FullscreenTransition(this.enabled);
  final bool enabled;
  final completed = Completer<void>();

  @override
  void onWindowEnterFullScreen() {
    if (enabled && !completed.isCompleted) completed.complete();
  }

  @override
  void onWindowLeaveFullScreen() {
    if (!enabled && !completed.isCompleted) completed.complete();
  }
}

class _DesktopWindowState {
  const _DesktopWindowState({
    required this.bounds,
    required this.fullscreen,
    required this.maximized,
    required this.alwaysOnTop,
  });
  final Rect bounds;
  final bool fullscreen;
  final bool maximized;
  final bool alwaysOnTop;
}
