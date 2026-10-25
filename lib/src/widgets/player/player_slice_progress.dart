import 'package:flutter/material.dart';

import '../../models/audio_slice.dart';

/// Keeps the playback track uniform while showing saved slice ranges.
class PlayerUniformSliderTrackShape extends SliderTrackShape {
  const PlayerUniformSliderTrackShape({
    this.slices = const [],
    this.duration = Duration.zero,
    this.pendingStartMs,
    this.sliceColor,
    this.activeSlice,
    this.selectedSlice,
    this.selectedSliceColor,
  });

  final List<AudioSlice> slices;
  final Duration duration;
  final int? pendingStartMs;
  final Color? sliceColor;
  final AudioSlice? activeSlice;
  final AudioSlice? selectedSlice;
  final Color? selectedSliceColor;

  static const _delegate = RoundedRectSliderTrackShape();

  @override
  bool get isRounded => true;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) => _delegate.getPreferredRect(
    parentBox: parentBox,
    offset: offset,
    sliderTheme: sliderTheme,
    isEnabled: isEnabled,
    isDiscrete: isDiscrete,
  );

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    _delegate.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
      textDirection: textDirection,
      additionalActiveTrackHeight: 0,
    );
    if (duration.inMilliseconds <= 0) return;
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final color = sliceColor ?? sliderTheme.activeTrackColor!;
    final activeColor = sliderTheme.activeTrackColor ?? color;
    final selectedColor = selectedSliceColor ?? activeColor;
    final pendingEdge = Paint()
      ..color = color
      ..strokeWidth = 2;
    double x(int milliseconds) {
      final fraction = (milliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
      return textDirection == TextDirection.rtl
          ? rect.right - rect.width * fraction
          : rect.left + rect.width * fraction;
    }

    final halfHeight = (sliderTheme.trackHeight ?? 2) / 2 + 2;
    for (final slice in slices) {
      if (slice.startMs >= duration.inMilliseconds) continue;
      final span = Rect.fromPoints(
        Offset(x(slice.startMs), rect.center.dy - halfHeight),
        Offset(x(slice.endMs), rect.center.dy + halfHeight),
      );
      final active = slice == activeSlice;
      final selected = slice == selectedSlice;
      final fill = Paint()
        ..color = (active ? activeColor : color).withValues(alpha: 0.4);
      final edge = Paint()
        ..color = selected
            ? selectedColor
            : active
            ? activeColor
            : color
        ..strokeWidth = selected
            ? 3
            : active
            ? 2.5
            : 2;
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(span, const Radius.circular(2)),
        fill,
      );
      for (final time in [slice.startMs, slice.endMs]) {
        context.canvas.drawLine(
          Offset(x(time), rect.center.dy - halfHeight),
          Offset(x(time), rect.center.dy + halfHeight),
          edge,
        );
      }
      if (selected) {
        context.canvas.drawRRect(
          RRect.fromRectAndRadius(span.inflate(2), const Radius.circular(3)),
          Paint()
            ..color = selectedColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }
    if (pendingStartMs case final start?) {
      context.canvas.drawLine(
        Offset(x(start), rect.center.dy - 7),
        Offset(x(start), rect.center.dy + 7),
        pendingEdge,
      );
    }
  }
}
