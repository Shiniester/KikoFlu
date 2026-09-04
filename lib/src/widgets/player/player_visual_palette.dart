import 'package:flutter/material.dart';

@immutable
class PlayerVisualPalette {
  const PlayerVisualPalette({
    required this.backgroundStart,
    required this.backgroundMiddle,
    required this.backgroundEnd,
    required this.foreground,
    required this.secondaryForeground,
    required this.accent,
    required this.onAccent,
    required this.panelColor,
    required this.panelStroke,
  });

  final Color backgroundStart;
  final Color backgroundMiddle;
  final Color backgroundEnd;
  final Color foreground;
  final Color secondaryForeground;
  final Color accent;
  final Color onAccent;
  final Color panelColor;
  final Color panelStroke;

  factory PlayerVisualPalette.fallback({
    required Color seed,
    required Brightness brightness,
    Color? accent,
    Color? onAccent,
  }) {
    return PlayerVisualPalette.fromDominant(
      seed,
      brightness: brightness,
      accent: accent,
      onAccent: onAccent,
    );
  }

  factory PlayerVisualPalette.fromDominant(
    Color dominant, {
    required Brightness brightness,
    Color? accent,
    Color? onAccent,
  }) {
    final sourceHsl = HSLColor.fromColor(dominant);
    final saturation = sourceHsl.saturation.clamp(0.28, 0.72);
    final startLightness = brightness == Brightness.dark ? 0.12 : 0.58;
    final middleLightness = brightness == Brightness.dark ? 0.21 : 0.70;
    final endLightness = brightness == Brightness.dark ? 0.33 : 0.82;

    final start = sourceHsl
        .withSaturation(saturation)
        .withLightness(startLightness)
        .toColor();
    final middle = sourceHsl
        .withHue((sourceHsl.hue + 8) % 360)
        .withSaturation((saturation * 0.88).clamp(0.22, 0.68))
        .withLightness(middleLightness)
        .toColor();
    final end = sourceHsl
        .withHue((sourceHsl.hue + 18) % 360)
        .withSaturation((saturation * 0.72).clamp(0.18, 0.62))
        .withLightness(endLightness)
        .toColor();

    final representative = Color.lerp(start, end, 0.5)!;
    final foreground = _bestForeground(representative);
    final resolvedAccent =
        accent ??
        sourceHsl
            .withSaturation((saturation + 0.12).clamp(0.36, 0.82))
            .withLightness(foreground == Colors.white ? 0.72 : 0.34)
            .toColor();
    final resolvedOnAccent = onAccent ?? _bestForeground(resolvedAccent);

    return PlayerVisualPalette(
      backgroundStart: start,
      backgroundMiddle: middle,
      backgroundEnd: end,
      foreground: foreground,
      secondaryForeground: foreground.withValues(alpha: 0.66),
      accent: resolvedAccent,
      onAccent: resolvedOnAccent,
      panelColor: foreground.withValues(
        alpha: foreground == Colors.white ? 0.10 : 0.07,
      ),
      panelStroke: foreground.withValues(alpha: 0.13),
    );
  }

  static Color _bestForeground(Color background) {
    final luminance = background.computeLuminance();
    final whiteContrast = 1.05 / (luminance + 0.05);
    final blackContrast = (luminance + 0.05) / 0.05;
    return whiteContrast >= blackContrast ? Colors.white : Colors.black;
  }
}
