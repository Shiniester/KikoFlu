import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const transparentSystemBarsStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  systemStatusBarContrastEnforced: false,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarContrastEnforced: false,
);

SystemUiOverlayStyle transparentSystemBarsForBrightness(Brightness brightness) {
  final iconBrightness = brightness == Brightness.light
      ? Brightness.dark
      : Brightness.light;

  return transparentSystemBarsStyle.copyWith(
    statusBarIconBrightness: iconBrightness,
    systemNavigationBarIconBrightness: iconBrightness,
  );
}

Future<void> enableEdgeToEdgeSystemUi() async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(transparentSystemBarsStyle);
}

/// Coordinates the persistent status-bar preference with temporary immersive
/// surfaces such as fullscreen lyrics.
class SystemUiModeCoordinator {
  SystemUiModeCoordinator._();

  static final SystemUiModeCoordinator instance = SystemUiModeCoordinator._();
  static const String hideStatusBarPreferenceKey = 'hide_status_bar_enabled';

  bool _hideStatusBar = false;
  bool _useEdgeToEdge = false;
  bool _immersiveOverride = false;

  bool get hideStatusBar => _hideStatusBar;

  Future<void> setPreference({
    required bool hideStatusBar,
    required bool useEdgeToEdge,
  }) async {
    _hideStatusBar = hideStatusBar;
    _useEdgeToEdge = useEdgeToEdge;
    if (!_immersiveOverride) await _applyBaseMode();
  }

  Future<void> enterImmersiveMode() async {
    _immersiveOverride = true;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> exitImmersiveMode() async {
    _immersiveOverride = false;
    await _applyBaseMode();
  }

  Future<void> restoreAfterImmersiveMode({
    required bool hideStatusBar,
    required bool useEdgeToEdge,
  }) async {
    _hideStatusBar = hideStatusBar;
    _useEdgeToEdge = useEdgeToEdge;
    _immersiveOverride = false;
    await _applyBaseMode();
  }

  Future<void> reapply() async {
    if (_immersiveOverride) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      return;
    }
    await _applyBaseMode();
  }

  Future<void> _applyBaseMode() async {
    if (_hideStatusBar) {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: const [SystemUiOverlay.bottom],
      );
      SystemChrome.setSystemUIOverlayStyle(transparentSystemBarsStyle);
      return;
    }
    if (_useEdgeToEdge) {
      await enableEdgeToEdgeSystemUi();
      return;
    }
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    SystemChrome.setSystemUIOverlayStyle(transparentSystemBarsStyle);
  }

  @visibleForTesting
  void debugResetState() {
    _hideStatusBar = false;
    _useEdgeToEdge = false;
    _immersiveOverride = false;
  }
}

Future<void> restoreSystemUiAfterImmersiveMode({
  required bool useEdgeToEdge,
  bool hideStatusBar = false,
}) async {
  await SystemUiModeCoordinator.instance.restoreAfterImmersiveMode(
    hideStatusBar: hideStatusBar,
    useEdgeToEdge: useEdgeToEdge,
  );
}
