import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/utils/system_ui_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(SystemUiModeCoordinator.instance.debugResetState);

  test('transparent system bars disable Android contrast scrims', () {
    expect(transparentSystemBarsStyle.statusBarColor, Colors.transparent);
    expect(
      transparentSystemBarsStyle.systemNavigationBarColor,
      Colors.transparent,
    );
    expect(
      transparentSystemBarsStyle.systemNavigationBarDividerColor,
      Colors.transparent,
    );
    expect(transparentSystemBarsStyle.systemStatusBarContrastEnforced, false);
    expect(
      transparentSystemBarsStyle.systemNavigationBarContrastEnforced,
      false,
    );
  });

  test('transparent system bars use readable icons for theme brightness', () {
    final lightStyle = transparentSystemBarsForBrightness(Brightness.light);
    final darkStyle = transparentSystemBarsForBrightness(Brightness.dark);

    expect(lightStyle.statusBarIconBrightness, Brightness.dark);
    expect(lightStyle.systemNavigationBarIconBrightness, Brightness.dark);
    expect(darkStyle.statusBarIconBrightness, Brightness.light);
    expect(darkStyle.systemNavigationBarIconBrightness, Brightness.light);
  });

  test(
    'edge-to-edge mode is enabled before applying transparent bars',
    () async {
      final calls = <MethodCall>[];
      final binding = TestDefaultBinaryMessengerBinding.instance;
      SystemChrome.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      await Future<void>.delayed(Duration.zero);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(() {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });

      await enableEdgeToEdgeSystemUi();
      await Future<void>.delayed(Duration.zero);

      expect(calls, hasLength(2));
      expect(calls[0].method, 'SystemChrome.setEnabledSystemUIMode');
      expect(calls[0].arguments, SystemUiMode.edgeToEdge.toString());
      expect(calls[1].method, 'SystemChrome.setSystemUIOverlayStyle');
    },
  );

  test('Android immersive exit restores edge-to-edge mode', () async {
    final calls = <MethodCall>[];
    final binding = TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await restoreSystemUiAfterImmersiveMode(useEdgeToEdge: true);

    expect(calls.first.method, 'SystemChrome.setEnabledSystemUIMode');
    expect(calls.first.arguments, SystemUiMode.edgeToEdge.toString());
    expect(
      calls.where(
        (call) => call.method == 'SystemChrome.setEnabledSystemUIOverlays',
      ),
      isEmpty,
    );
  });

  test('hidden status bar keeps the bottom navigation overlay', () async {
    final calls = <MethodCall>[];
    final binding = TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await SystemUiModeCoordinator.instance.setPreference(
      hideStatusBar: true,
      useEdgeToEdge: true,
    );

    final overlayCall = calls.firstWhere(
      (call) => call.method == 'SystemChrome.setEnabledSystemUIOverlays',
    );
    expect(overlayCall.arguments, [SystemUiOverlay.bottom.toString()]);
  });

  test('fullscreen lyrics restore the hidden status-bar preference', () async {
    final calls = <MethodCall>[];
    final binding = TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await SystemUiModeCoordinator.instance.setPreference(
      hideStatusBar: true,
      useEdgeToEdge: true,
    );
    await SystemUiModeCoordinator.instance.enterImmersiveMode();
    calls.clear();
    await SystemUiModeCoordinator.instance.exitImmersiveMode();

    expect(
      calls.any(
        (call) =>
            call.method == 'SystemChrome.setEnabledSystemUIOverlays' &&
            '${call.arguments}'.contains('SystemUiOverlay.bottom'),
      ),
      isTrue,
    );
  });
}
