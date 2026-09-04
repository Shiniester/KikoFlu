import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/platform_appearance_service.dart';

void main() {
  test('macOS system theme resolves from native effective appearance', () {
    expect(
      PlatformAppearanceService.resolveMacOSThemeMode(
        ThemeMode.system,
        Brightness.dark,
      ),
      ThemeMode.dark,
    );
    expect(
      PlatformAppearanceService.resolveMacOSThemeMode(
        ThemeMode.system,
        Brightness.light,
      ),
      ThemeMode.light,
    );
  });

  test('explicit theme mode is never replaced by system appearance', () {
    expect(
      PlatformAppearanceService.resolveMacOSThemeMode(
        ThemeMode.light,
        Brightness.dark,
      ),
      ThemeMode.light,
    );
    expect(
      PlatformAppearanceService.resolveMacOSThemeMode(
        ThemeMode.dark,
        Brightness.light,
      ),
      ThemeMode.dark,
    );
  });
}
