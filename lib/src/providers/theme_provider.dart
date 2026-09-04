import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 主题模式枚举
enum AppThemeMode {
  system, // 跟随系统
  light, // 浅色模式
  dark, // 深色模式
}

// 颜色方案类型枚举
enum ColorSchemeType {
  oceanBlue, // 海洋蓝（默认）
  forestGreen, // 森林绿
  sunsetOrange, // 日落橙
  lavenderPurple, // 薰衣草紫
  sakuraPink, // 樱花粉
}

// 主题设置状态
class ThemeSettings {
  final AppThemeMode themeMode;
  final ColorSchemeType colorSchemeType;
  final bool dynamicColorEnabled;

  const ThemeSettings({
    this.themeMode = AppThemeMode.system,
    this.colorSchemeType = ColorSchemeType.oceanBlue,
    this.dynamicColorEnabled = true,
  });

  ThemeSettings copyWith({
    AppThemeMode? themeMode,
    ColorSchemeType? colorSchemeType,
    bool? dynamicColorEnabled,
  }) {
    return ThemeSettings(
      themeMode: themeMode ?? this.themeMode,
      colorSchemeType: colorSchemeType ?? this.colorSchemeType,
      dynamicColorEnabled: dynamicColorEnabled ?? this.dynamicColorEnabled,
    );
  }

  ThemeMode toThemeMode() {
    switch (themeMode) {
      case AppThemeMode.system:
        return ThemeMode.system;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
    }
  }
}

// 主题设置控制器
class ThemeSettingsNotifier extends StateNotifier<ThemeSettings> {
  static const String _themeModeKey = 'theme_mode';
  static const String _colorSchemeTypeKey = 'color_scheme_type';
  static const String dynamicColorEnabledKey = 'dynamic_color_enabled';

  /// `ColorSchemeType.dynamic` occupied index 5 before dynamic color became
  /// an independent setting.
  static const int legacyDynamicColorSchemeIndex = 5;

  bool _changedLocally = false;

  ThemeSettingsNotifier() : super(const ThemeSettings()) {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    final storedThemeModeIndex = prefs.getInt(_themeModeKey);
    final storedColorSchemeTypeIndex = prefs.getInt(_colorSchemeTypeKey);
    final storedDynamicColorEnabled = prefs.getBool(dynamicColorEnabledKey);
    if (!mounted || _changedLocally) return;

    final themeMode =
        storedThemeModeIndex != null &&
            storedThemeModeIndex >= 0 &&
            storedThemeModeIndex < AppThemeMode.values.length
        ? AppThemeMode.values[storedThemeModeIndex]
        : AppThemeMode.system;
    final colorSchemeType =
        storedColorSchemeTypeIndex != null &&
            storedColorSchemeTypeIndex >= 0 &&
            storedColorSchemeTypeIndex < ColorSchemeType.values.length
        ? ColorSchemeType.values[storedColorSchemeTypeIndex]
        : ColorSchemeType.oceanBlue;
    final dynamicColorEnabled =
        storedDynamicColorEnabled ??
        (storedColorSchemeTypeIndex == null ||
            storedColorSchemeTypeIndex == legacyDynamicColorSchemeIndex);

    state = ThemeSettings(
      themeMode: themeMode,
      colorSchemeType: colorSchemeType,
      dynamicColorEnabled: dynamicColorEnabled,
    );

    if (storedDynamicColorEnabled == null) {
      await prefs.setBool(dynamicColorEnabledKey, dynamicColorEnabled);
    }
    if (storedColorSchemeTypeIndex == legacyDynamicColorSchemeIndex) {
      await prefs.setInt(_colorSchemeTypeKey, colorSchemeType.index);
    }
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    _changedLocally = true;
    state = state.copyWith(themeMode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_themeModeKey, mode.index);
  }

  Future<void> setColorSchemeType(ColorSchemeType type) async {
    _changedLocally = true;
    state = state.copyWith(colorSchemeType: type);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_colorSchemeTypeKey, type.index);
  }

  Future<void> setDynamicColorEnabled(bool enabled) async {
    _changedLocally = true;
    state = state.copyWith(dynamicColorEnabled: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(dynamicColorEnabledKey, enabled);
  }

  Future<void> resetToDefault() async {
    _changedLocally = true;
    state = const ThemeSettings();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_themeModeKey, AppThemeMode.system.index);
    await prefs.setInt(_colorSchemeTypeKey, ColorSchemeType.oceanBlue.index);
    await prefs.setBool(dynamicColorEnabledKey, true);
  }
}

// 主题设置提供者
final themeSettingsProvider =
    StateNotifierProvider<ThemeSettingsNotifier, ThemeSettings>((ref) {
      return ThemeSettingsNotifier();
    });
