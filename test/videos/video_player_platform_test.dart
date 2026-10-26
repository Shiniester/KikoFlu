import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/videos/video_player_platform.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

class _Controller implements VideoController {
  _Controller({this.firstFrame, this.nativePlayer});
  final Completer<void>? firstFrame;
  final Player? nativePlayer;
  @override
  Player get player => nativePlayer!;
  @override
  Future<void> get waitUntilFirstFrameRendered =>
      firstFrame?.future ?? Future<void>.value();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PlayerStreams implements PlayerStream {
  final playingChanges = StreamController<bool>.broadcast(sync: true);
  @override
  Stream<bool> get playing => playingChanges.stream;
  @override
  Stream<Duration> get position => const Stream<Duration>.empty();
  @override
  Stream<Duration> get duration => const Stream<Duration>.empty();
  @override
  Stream<double> get rate => const Stream<double>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements Player {
  @override
  PlayerState state = const PlayerState(
    playing: true,
    position: Duration(seconds: 10),
    duration: Duration(seconds: 60),
    rate: 1.5,
  );
  @override
  final _PlayerStreams stream = _PlayerStreams();
  @override
  Future<int> get handle async => 42;
  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    stream.playingChanges.add(false);
  }

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
    stream.playingChanges.add(true);
  }

  @override
  Future<void> seek(Duration position) async {
    state = state.copyWith(position: position);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Window implements WindowManager {
  Rect bounds = const Rect.fromLTWH(120, 80, 1280, 720);
  bool fullscreen = false;
  bool maximized = false;
  bool alwaysOnTop = false;
  Size minimumSize = const Size(350, 600);
  bool failEntering = false;
  bool failFullscreen = false;
  int fullscreenRequests = 0;
  bool delayFullscreenEvents = false;
  Completer<void>? fullscreenChange;
  bool simulateWindowsFullscreen = false;
  Rect? _boundsBeforeFullscreen;
  bool? _maximizedBeforeFullscreen;
  final fullscreenStarted = Completer<void>();
  final windowListeners = <WindowListener>[];
  Completer<void>? resize;
  final resizeStarted = Completer<void>();

  @override
  Future<bool> isFullScreen() async => fullscreen;
  @override
  Future<bool> isMaximized() async => maximized;
  @override
  Future<bool> isAlwaysOnTop() async => alwaysOnTop;
  @override
  Future<Rect> getBounds() async => bounds;
  @override
  Future<void> setFullScreen(bool value) async {
    fullscreenRequests++;
    if (value && failFullscreen) {
      throw PlatformException(code: 'fullscreen_rejected');
    }
    if (!fullscreenStarted.isCompleted) fullscreenStarted.complete();
    if (fullscreenChange != null) await fullscreenChange!.future;
    if (simulateWindowsFullscreen) {
      if (value && !fullscreen) {
        _boundsBeforeFullscreen = bounds;
        _maximizedBeforeFullscreen = maximized;
        bounds = const Rect.fromLTWH(0, 0, 1920, 1080);
        maximized = true;
      } else if (!value && fullscreen) {
        bounds = _boundsBeforeFullscreen!;
        maximized = _maximizedBeforeFullscreen!;
      }
    }
    fullscreen = value;
    if (!delayFullscreenEvents) finishFullscreenTransition();
  }

  void finishFullscreenTransition() {
    for (final listener in List<WindowListener>.of(windowListeners)) {
      if (fullscreen) {
        listener.onWindowEnterFullScreen();
      } else {
        listener.onWindowLeaveFullScreen();
      }
    }
  }

  @override
  void addListener(WindowListener listener) {
    windowListeners.add(listener);
  }

  @override
  void removeListener(WindowListener listener) {
    windowListeners.remove(listener);
  }

  @override
  Future<void> unmaximize() async {
    maximized = false;
  }

  @override
  Future<void> maximize({bool vertically = false}) async {
    maximized = true;
  }

  @override
  Future<void> setMinimumSize(Size value) async {
    minimumSize = value;
  }

  @override
  Future<void> setSize(Size value, {bool animate = false}) async {
    if (!resizeStarted.isCompleted) resizeStarted.complete();
    if (resize != null) await resize!.future;
    bounds = bounds.topLeft & value;
  }

  @override
  Future<void> setAlwaysOnTop(bool value) async {
    if (value && failEntering) throw PlatformException(code: 'rejected');
    alwaysOnTop = value;
  }

  @override
  Future<void> setBounds(
    Rect? value, {
    Offset? position,
    Size? size,
    bool animate = false,
  }) async {
    bounds = value!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('video-platform-test');
  const pipChannel = MethodChannel('video-pip-test');
  final calls = <MethodCall>[];
  final controller = _Controller(nativePlayer: _Player());
  var failFullscreenStatusBarChanges = false;

  setUp(() {
    calls.clear();
    failFullscreenStatusBarChanges = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'initialize') {
        return {'brightness': true, 'pictureInPicture': true};
      }
      if (call.method == 'getBrightness') return 0.7;
      if (call.method == 'enterPictureInPicture') return true;
      if (call.method == 'setFullscreenStatusBarHidden' &&
          failFullscreenStatusBarChanges) {
        throw PlatformException(code: 'status_bar_unavailable');
      }
      return null;
    });
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pipChannel, null);
  });

  test(
    'battery status preserves native values and returns null when unknown',
    () async {
      Map<String, dynamic>? battery = {'level': 73, 'charging': true};
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'initialize') return <String, dynamic>{};
        if (call.method == 'getBatteryStatus') return battery;
        return null;
      });
      final platform = VideoPlayerPlatform(
        channel: channel,
        platform: TargetPlatform.android,
      );
      await platform.initialize();
      expect(platform.supportsBatteryStatus, isTrue);
      expect(await platform.getBatteryStatus(), (level: 73, charging: true));
      expect(calls.last.method, 'getBatteryStatus');
      battery = null;
      expect(await platform.getBatteryStatus(), isNull);
      battery = {'level': -1, 'charging': false};
      expect(await platform.getBatteryStatus(), isNull);
      await platform.dispose();
      expect(await platform.getBatteryStatus(), isNull);
      final desktop = VideoPlayerPlatform(
        channel: channel,
        platform: TargetPlatform.windows,
      );
      expect(desktop.supportsBatteryStatus, isFalse);
      expect(await desktop.getBatteryStatus(), isNull);
      await desktop.dispose();
    },
  );

  test('fullscreen status bar visibility is Android only', () async {
    final android = VideoPlayerPlatform(
      channel: channel,
      platform: TargetPlatform.android,
    );
    await android.initialize();
    await android.setFullscreenStatusBarHidden(true);
    await android.setFullscreenStatusBarHidden(false);
    expect(
      calls
          .where((call) => call.method == 'setFullscreenStatusBarHidden')
          .map((call) => call.arguments),
      [
        {'hidden': true},
        {'hidden': false},
      ],
    );
    calls.clear();
    failFullscreenStatusBarChanges = true;
    await android.setFullscreenStatusBarHidden(true);
    await android.setFullscreenStatusBarHidden(false);
    expect(
      calls
          .where((call) => call.method == 'setFullscreenStatusBarHidden')
          .map((call) => call.arguments),
      [
        {'hidden': true},
        {'hidden': false},
      ],
    );
    failFullscreenStatusBarChanges = false;
    await android.dispose();

    calls.clear();
    final ios = VideoPlayerPlatform(
      channel: channel,
      platform: TargetPlatform.iOS,
    );
    await ios.initialize();
    await ios.setFullscreenStatusBarHidden(true);
    await ios.setFullscreenStatusBarHidden(false);
    expect(
      calls.where((call) => call.method == 'setFullscreenStatusBarHidden'),
      isEmpty,
    );
    await ios.dispose();
  });

  test(
    'brightness is bounded and temporary state is restored on dispose',
    () async {
      final platform = VideoPlayerPlatform(
        channel: channel,
        platform: TargetPlatform.android,
      );
      await platform.initialize();
      expect(platform.supportsBrightness, isTrue);
      expect(await platform.getBrightness(), 0.7);
      await platform.setBrightness(1.4);
      expect(calls.last.arguments, {'value': 1.0});
      await platform.setKeepScreenOn(true);
      await platform.dispose();
      expect(
        calls.map((call) => call.method),
        containsAllInOrder([
          'setBrightness',
          'setKeepScreenOn',
          'exitPictureInPicture',
          'resetBrightness',
          'dispose',
        ]),
      );
    },
  );

  test(
    'PiP activity comes from native callbacks, not accepted entry requests',
    () async {
      final platform = VideoPlayerPlatform(
        channel: channel,
        platform: TargetPlatform.android,
      );
      await platform.initialize();
      expect(
        await platform.enterPictureInPicture(controller, aspectRatio: 16 / 9),
        isTrue,
      );
      expect(platform.pictureInPicture.value, isFalse);
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('pictureInPictureChanged', true),
        ),
        (_) {},
      );
      expect(platform.pictureInPicture.value, isTrue);
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('pictureInPictureChanged', false),
        ),
        (_) {},
      );
      expect(platform.pictureInPicture.value, isFalse);
      await platform.dispose();
    },
  );

  test('rejected native PiP does not report activity', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'initialize') return {'pictureInPicture': true};
      if (call.method == 'enterPictureInPicture') {
        throw PlatformException(code: 'rejected');
      }
      return null;
    });
    final platform = VideoPlayerPlatform(
      channel: channel,
      platform: TargetPlatform.android,
    );
    await platform.initialize();
    expect(
      await platform.enterPictureInPicture(controller, aspectRatio: 16 / 9),
      isFalse,
    );
    expect(platform.pictureInPicture.value, isFalse);
    await platform.dispose();
  });

  test(
    'old iOS keeps brightness when sample-buffer PiP is unavailable',
    () async {
      final platform = VideoPlayerPlatform(
        channel: channel,
        pictureInPictureChannel: pipChannel,
        platform: TargetPlatform.iOS,
      );
      await platform.initialize();
      expect(platform.supportsBrightness, isTrue);
      expect(platform.supportsPictureInPicture, isFalse);
      await platform.dispose();
    },
  );

  test('iOS PiP controls and timeline use the existing player', () async {
    final states = <dynamic>[];
    Future<void> nativeCall(String method, dynamic arguments) =>
        binding.defaultBinaryMessenger.handlePlatformMessage(
          pipChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (_) {},
        );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pipChannel, (
      call,
    ) async {
      if (call.method == 'isSupported') return true;
      if (call.method == 'enterPictureInPicture') {
        expect(call.arguments['handle'], '42');
        await nativeCall('pictureInPictureChanged', true);
        return true;
      }
      if (call.method == 'updateState') states.add(call.arguments);
      return null;
    });
    final player = _Player();
    final platform = VideoPlayerPlatform(
      channel: channel,
      pictureInPictureChannel: pipChannel,
      platform: TargetPlatform.iOS,
    );
    await platform.initialize();
    expect(
      await platform.enterPictureInPicture(
        _Controller(nativePlayer: player),
        aspectRatio: 16 / 9,
      ),
      isTrue,
    );
    expect(states.first, {
      'position': 10.0,
      'duration': 60.0,
      'playing': true,
      'rate': 1.5,
    });
    await nativeCall('setPlaying', false);
    expect(player.state.playing, isFalse);
    await nativeCall('skipByInterval', 100.0);
    expect(player.state.position, const Duration(seconds: 60));
    await platform.dispose();
    expect(player.stream.playingChanges.hasListener, isFalse);
    await player.stream.playingChanges.close();
  });

  test(
    'Android binds video controls before PiP and requests brightness permission only explicitly',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'initialize') {
          return {'brightness': true, 'pictureInPicture': true};
        }
        if (call.method == 'setSystemBrightnessMode') return false;
        if (call.method == 'getSystemBrightnessMode') return false;
        return null;
      });
      final player = _Player();
      final platform = VideoPlayerPlatform(
        channel: channel,
        platform: TargetPlatform.android,
      );
      await platform.initialize();
      expect(platform.supportsSystemBrightness, isTrue);
      expect(await platform.setSystemBrightnessMode(true), isFalse);
      expect(
        calls.where(
          (call) => call.method == 'requestSystemBrightnessPermission',
        ),
        isEmpty,
      );
      await platform.requestSystemBrightnessPermission();
      expect(calls.last.method, 'requestSystemBrightnessPermission');
      await platform.attachVideoController(_Controller(nativePlayer: player));
      expect(calls.last.method, 'updateState');
      await platform.setBackgroundPlayback(true);
      expect(calls.last.arguments, {'enabled': true});
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('setPlaying', false),
        ),
        (_) {},
      );
      expect(player.state.playing, isFalse);
      await platform.setAutoPictureInPicture(true, aspectRatio: 4 / 3);
      expect(
        calls
            .where((call) => call.method == 'setAutoPictureInPicture')
            .single
            .arguments,
        {'enabled': true, 'aspectRatio': 4 / 3},
      );
      await platform.setGravityOrientation(true);
      expect(calls.last.method, 'setGravityOrientation');
      await platform.dispose();
      expect(player.stream.playingChanges.hasListener, isFalse);
      await player.stream.playingChanges.close();
    },
  );

  test('old pending entry cannot clear the next platform owner', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pipChannel, (
      call,
    ) async {
      if (call.method == 'isSupported') return true;
      return null;
    });
    final old = VideoPlayerPlatform(
      channel: channel,
      pictureInPictureChannel: pipChannel,
      platform: TargetPlatform.iOS,
    );
    await old.initialize();
    final frame = Completer<void>();
    final entering = old.enterPictureInPicture(
      _Controller(firstFrame: frame),
      aspectRatio: 16 / 9,
    );
    final disposing = old.dispose();
    final next = VideoPlayerPlatform(
      channel: channel,
      pictureInPictureChannel: pipChannel,
      platform: TargetPlatform.iOS,
    );
    final initializing = next.initialize();
    frame.complete();
    expect(await entering, isFalse);
    await disposing;
    await initializing;
    final nativeCalls = calls.length;
    await old.dispose();
    expect(calls.length, nativeCalls);
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      pipChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('pictureInPictureChanged', true),
      ),
      (_) {},
    );
    expect(next.pictureInPicture.value, isTrue);
    await next.dispose();
  });

  test(
    'covered platform reacquires its channel after the top page closes',
    () async {
      final first = VideoPlayerPlatform(
        channel: channel,
        platform: TargetPlatform.android,
      );
      final second = VideoPlayerPlatform(
        channel: channel,
        platform: TargetPlatform.android,
      );
      await first.initialize();
      await second.initialize();
      await second.dispose();
      await first.initialize();
      expect(await first.getBrightness(), 0.7);
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('pictureInPictureChanged', true),
        ),
        (_) {},
      );
      expect(first.pictureInPicture.value, isTrue);
      await first.dispose();
    },
  );

  test(
    'desktop PiP preserves bounds, topmost, maximized and fullscreen states',
    () async {
      final window = _Window()
        ..fullscreen = true
        ..maximized = true
        ..alwaysOnTop = true;
      final original = window.bounds;
      final platform = VideoPlayerPlatform(
        channel: channel,
        desktopWindow: window,
        platform: TargetPlatform.windows,
      );
      await platform.initialize();
      expect(
        await platform.enterPictureInPicture(controller, aspectRatio: 16 / 9),
        isTrue,
      );
      expect(window.bounds.size, const Size(480, 270));
      expect(window.fullscreen, isFalse);
      await platform.exitPictureInPicture();
      expect(window.bounds, original);
      expect(window.minimumSize, const Size(350, 600));
      expect(window.alwaysOnTop, isTrue);
      expect(window.fullscreen, isTrue);
      expect(window.maximized, isTrue);
      await platform.dispose();
    },
  );

  test(
    'native fullscreen restores the original desktop state on exit and dispose',
    () async {
      final window = _Window();
      final platform = VideoPlayerPlatform(
        channel: channel,
        desktopWindow: window,
        platform: TargetPlatform.windows,
      );
      await platform.initialize();
      await platform.setNativeFullscreen(true);
      expect(window.fullscreen, isTrue);
      await platform.setNativeFullscreen(false);
      expect(window.fullscreen, isFalse);
      await platform.setNativeFullscreen(true);
      await platform.dispose();
      expect(window.fullscreen, isFalse);

      window.fullscreen = true;
      final existingFullscreen = VideoPlayerPlatform(
        channel: channel,
        desktopWindow: window,
        platform: TargetPlatform.macOS,
      );
      await existingFullscreen.initialize();
      await existingFullscreen.setNativeFullscreen(true);
      await existingFullscreen.setNativeFullscreen(false);
      expect(window.fullscreen, isTrue);
      await existingFullscreen.dispose();
    },
  );

  test(
    'PiP returns to native fullscreen before disposal restores the original window',
    () async {
      final window = _Window();
      final original = window.bounds;
      final platform = VideoPlayerPlatform(
        channel: channel,
        desktopWindow: window,
        platform: TargetPlatform.windows,
      );
      await platform.initialize();
      await platform.setNativeFullscreen(true);
      expect(
        await platform.enterPictureInPicture(controller, aspectRatio: 16 / 9),
        isTrue,
      );
      expect(window.fullscreen, isFalse);
      await platform.exitPictureInPicture();
      expect(window.fullscreen, isTrue);
      expect(window.bounds, original);
      await platform.enterPictureInPicture(controller, aspectRatio: 16 / 9);
      await platform.dispose();
      expect(window.fullscreen, isFalse);
      expect(window.bounds, original);
    },
  );

  test(
    'native fullscreen request exits PiP and restores its window first',
    () async {
      final window = _Window();
      final original = window.bounds;
      final platform = VideoPlayerPlatform(
        channel: channel,
        desktopWindow: window,
        platform: TargetPlatform.linux,
      );
      await platform.initialize();
      await platform.enterPictureInPicture(controller, aspectRatio: 16 / 9);
      await platform.setNativeFullscreen(true);
      expect(platform.pictureInPicture.value, isFalse);
      expect(window.fullscreen, isTrue);
      expect(window.bounds, original);
      expect(window.alwaysOnTop, isFalse);
      await platform.dispose();
      expect(window.fullscreen, isFalse);
    },
  );

  test('native fullscreen failure restores the original value', () async {
    final window = _Window()..failFullscreen = true;
    final platform = VideoPlayerPlatform(
      channel: channel,
      desktopWindow: window,
      platform: TargetPlatform.windows,
    );
    await platform.initialize();
    await expectLater(
      platform.setNativeFullscreen(true),
      throwsA(isA<PlatformException>()),
    );
    expect(window.fullscreen, isFalse);
    await platform.dispose();
  });

  test(
    'mobile and inactive platform fullscreen calls do not enter a busy queue',
    () async {
      final window = _Window()..resize = Completer<void>();
      final active = VideoPlayerPlatform(
        channel: channel,
        desktopWindow: window,
        platform: TargetPlatform.windows,
      );
      await active.initialize();
      final entering = active.enterPictureInPicture(
        controller,
        aspectRatio: 16 / 9,
      );
      await window.resizeStarted.future;
      final disposing = active.dispose();
      final inactive = VideoPlayerPlatform(
        channel: channel,
        desktopWindow: window,
        platform: TargetPlatform.windows,
      );
      final mobile = VideoPlayerPlatform(
        channel: channel,
        platform: TargetPlatform.android,
      );
      await inactive.setNativeFullscreen(true);
      await mobile.setNativeFullscreen(true);
      await inactive.dispose();
      await mobile.dispose();
      expect(window.fullscreenRequests, 0);
      window.resize!.complete();
      expect(await entering, isFalse);
      await disposing;
    },
  );

  test(
    'macOS PiP waits for native fullscreen animation before resizing',
    () async {
      final window = _Window()..delayFullscreenEvents = true;
      final original = window.bounds;
      final platform = VideoPlayerPlatform(
        channel: channel,
        desktopWindow: window,
        platform: TargetPlatform.macOS,
      );
      await platform.initialize();
      final fullscreen = platform.setNativeFullscreen(true);
      await window.fullscreenStarted.future;
      final entering = platform.enterPictureInPicture(
        controller,
        aspectRatio: 16 / 9,
      );
      expect(window.bounds, original);
      expect(window.windowListeners, hasLength(1));
      // Later transitions complete immediately, as a native delegate event would.
      window.delayFullscreenEvents = false;
      window.finishFullscreenTransition();
      await fullscreen;
      expect(await entering, isTrue);
      expect(window.bounds.size, const Size(480, 270));
      expect(window.windowListeners, isEmpty);
      await platform.dispose();
      expect(window.fullscreen, isFalse);
      expect(window.bounds, original);
      expect(window.windowListeners, isEmpty);
    },
  );

  test('PiP waits when native fullscreen starts changing first', () async {
    final window = _Window()..fullscreenChange = Completer<void>();
    final original = window.bounds;
    final platform = VideoPlayerPlatform(
      channel: channel,
      desktopWindow: window,
      platform: TargetPlatform.windows,
    );
    await platform.initialize();
    final fullscreen = platform.setNativeFullscreen(true);
    await window.fullscreenStarted.future;
    final entering = platform.enterPictureInPicture(
      controller,
      aspectRatio: 16 / 9,
    );
    expect(window.fullscreen, isFalse);
    expect(window.bounds, original);
    expect(platform.pictureInPicture.value, isFalse);
    window.fullscreenChange!.complete();
    await fullscreen;
    expect(await entering, isTrue);
    expect(window.fullscreen, isFalse);
    expect(window.bounds.size, const Size(480, 270));
    await platform.dispose();
    expect(window.fullscreen, isFalse);
    expect(window.bounds, original);
  });

  test('pin restores its original state after fullscreen and PiP', () async {
    for (final original in [false, true]) {
      final window = _Window()..alwaysOnTop = original;
      final platform = VideoPlayerPlatform(
        channel: channel,
        desktopWindow: window,
        platform: TargetPlatform.windows,
      );
      await platform.initialize();
      expect(await platform.isAlwaysOnTop(), original);
      await platform.setAlwaysOnTop(!original);
      expect(await platform.isAlwaysOnTop(), !original);
      await platform.setNativeFullscreen(true);
      await platform.enterPictureInPicture(controller, aspectRatio: 16 / 9);
      await platform.exitPictureInPicture();
      expect(await platform.isAlwaysOnTop(), !original);
      await platform.dispose();
      expect(window.alwaysOnTop, original);
      expect(window.fullscreen, isFalse);
    }
  });

  test(
    'owner takeover does not wait for the old owners later window operations',
    () async {
      final window = _Window();
      final first = VideoPlayerPlatform(
        channel: channel,
        desktopWindow: window,
        platform: TargetPlatform.windows,
      );
      final second = VideoPlayerPlatform(
        channel: channel,
        desktopWindow: window,
        platform: TargetPlatform.windows,
      );
      await first.initialize();
      final takingOver = second.initialize();
      final fullscreen = first.setNativeFullscreen(true);
      final entering = first.enterPictureInPicture(
        controller,
        aspectRatio: 16 / 9,
      );
      await takingOver;
      await fullscreen;
      expect(await entering, isFalse);
      expect(window.fullscreenRequests, 0);
      expect(second.supportsPictureInPicture, isTrue);
      expect(await second.isAlwaysOnTop(), isFalse);
      await first.dispose();
      await second.dispose();
    },
  );

  test(
    'Windows fullscreen temporary maximization does not leak through PiP',
    () async {
      final window = _Window()..simulateWindowsFullscreen = true;
      final original = window.bounds;
      final platform = VideoPlayerPlatform(
        channel: channel,
        desktopWindow: window,
        platform: TargetPlatform.windows,
      );
      await platform.initialize();
      await platform.setNativeFullscreen(true);
      expect(window.maximized, isTrue);
      await platform.enterPictureInPicture(controller, aspectRatio: 16 / 9);
      expect(window.maximized, isFalse);
      await platform.exitPictureInPicture();
      expect(window.fullscreen, isTrue);
      await platform.setNativeFullscreen(false);
      expect(window.fullscreen, isFalse);
      expect(window.maximized, isFalse);
      expect(window.bounds, original);
      await platform.dispose();
    },
  );

  test('desktop failure restores original window', () async {
    final window = _Window()..failEntering = true;
    final original = window.bounds;
    final platform = VideoPlayerPlatform(
      channel: channel,
      desktopWindow: window,
      platform: TargetPlatform.linux,
    );
    await platform.initialize();
    expect(
      await platform.enterPictureInPicture(controller, aspectRatio: 16 / 9),
      isFalse,
    );
    expect(window.bounds, original);
    expect(window.minimumSize, const Size(350, 600));
    expect(window.alwaysOnTop, isFalse);
    await platform.dispose();
  });

  test(
    'disposal during desktop entry restores the window after resize finishes',
    () async {
      final window = _Window()..resize = Completer<void>();
      final original = window.bounds;
      final platform = VideoPlayerPlatform(
        channel: channel,
        desktopWindow: window,
        platform: TargetPlatform.macOS,
      );
      await platform.initialize();
      final entering = platform.enterPictureInPicture(
        controller,
        aspectRatio: 16 / 9,
      );
      await window.resizeStarted.future;
      final disposing = platform.dispose();
      window.resize!.complete();
      expect(await entering, isFalse);
      await disposing;
      expect(window.bounds, original);
      expect(window.alwaysOnTop, isFalse);
      expect(window.minimumSize, const Size(350, 600));
    },
  );
}
