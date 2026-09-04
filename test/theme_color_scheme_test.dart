import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/utils/theme.dart';

void main() {
  test('cover seed takes priority over the system dynamic scheme', () {
    const artworkSeed = Color(0xFFE53935);
    final systemScheme = ColorScheme.fromSeed(seedColor: Colors.blue);

    final resolved = AppTheme.resolveDynamicColorScheme(
      enabled: true,
      artworkSeed: artworkSeed,
      systemScheme: systemScheme,
      brightness: Brightness.light,
    );

    expect(
      resolved,
      AppTheme.colorSchemeFromSeed(artworkSeed, Brightness.light),
    );
  });

  test('system dynamic scheme is used when artwork is unavailable', () {
    final systemScheme = ColorScheme.fromSeed(seedColor: Colors.blue);

    final resolved = AppTheme.resolveDynamicColorScheme(
      enabled: true,
      artworkSeed: null,
      systemScheme: systemScheme,
      brightness: Brightness.light,
    );

    expect(identical(resolved, systemScheme), isTrue);
  });

  test('fixed color is left to AppTheme when dynamic color is disabled', () {
    final resolved = AppTheme.resolveDynamicColorScheme(
      enabled: false,
      artworkSeed: Colors.red,
      systemScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      brightness: Brightness.light,
    );

    expect(resolved, isNull);
  });
}
