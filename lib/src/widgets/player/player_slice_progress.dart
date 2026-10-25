import 'dart:ui' show ClipOp, PathOperation;

import 'package:flutter/material.dart';

import '../../models/audio_slice.dart';

/// Keeps the playback track uniform while showing saved slice ranges.
class PlayerUniformSliderTrackShape extends SliderTrackShape {
  const PlayerUniformSliderTrackShape({
    this.slices = const [],
    this.duration = Duration.zero,
    this.pendingStartMs,
    this.onlySlices = false,
    this.activeSlice,
    this.selectedSlice,
    this.selectedSliceColor,
  });

  final List<AudioSlice> slices;
  final Duration duration;
  final int? pendingStartMs;
  final bool onlySlices;
  final AudioSlice? activeSlice;
  final AudioSlice? selectedSlice;
  final Color? selectedSliceColor;

  static const _delegate = RectangularSliderTrackShape();

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
    void paintTrack(SliderThemeData theme) {
      context.canvas.save();
      context.canvas.clipRRect(
        RRect.fromRectAndRadius(
          getPreferredRect(
            parentBox: parentBox,
            offset: offset,
            sliderTheme: theme,
            isEnabled: isEnabled,
            isDiscrete: isDiscrete,
          ),
          Radius.circular((theme.trackHeight ?? 2) / 2),
        ),
      );
      _delegate.paint(
        context,
        offset,
        parentBox: parentBox,
        sliderTheme: theme,
        enableAnimation: enableAnimation,
        thumbCenter: thumbCenter,
        secondaryOffset: secondaryOffset,
        isEnabled: isEnabled,
        isDiscrete: isDiscrete,
        textDirection: textDirection,
      );
      context.canvas.restore();
    }

    if (duration.inMilliseconds <= 0) {
      paintTrack(sliderTheme);
      return;
    }
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final activeColor = sliderTheme.activeTrackColor!;
    final selectedColor = selectedSliceColor ?? activeColor;
    final pendingEdge = Paint()
      ..color = activeColor
      ..strokeWidth = 2;
    double x(int milliseconds) {
      final fraction = (milliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
      return textDirection == TextDirection.rtl
          ? rect.right - rect.width * fraction
          : rect.left + rect.width * fraction;
    }

    Rect sliceRect(AudioSlice slice) {
      final span = Rect.fromPoints(
        Offset(x(slice.startMs), rect.top),
        Offset(x(slice.endMs), rect.bottom),
      );
      // Keep short slices visible without changing their saved times.
      final minimumWidth = rect.width.clamp(0.0, 2.0);
      final width = span.width.clamp(minimumWidth, rect.width).toDouble();
      final left = (span.center.dx - width / 2)
          .clamp(rect.left, rect.right - width)
          .toDouble();
      return Rect.fromLTWH(left, rect.top, width, rect.height);
    }

    final visibleSlices = slices.where(
      (slice) => slice.startMs < duration.inMilliseconds,
    );
    context.canvas.save();
    // Avoid blending the translucent track twice inside a slice.
    for (final slice in visibleSlices) {
      context.canvas.clipRect(
        sliceRect(slice),
        clipOp: ClipOp.difference,
        doAntiAlias: false,
      );
    }
    paintTrack(
      onlySlices && visibleSlices.isNotEmpty
          ? sliderTheme.copyWith(
              activeTrackColor: sliderTheme.inactiveTrackColor,
              disabledActiveTrackColor: sliderTheme.disabledInactiveTrackColor,
            )
          : sliderTheme,
    );
    context.canvas.restore();

    // Minimum-width slices can overlap; paint their shared area only once.
    final paintedSlices = Path();
    for (final slice in visibleSlices) {
      final active = slice == activeSlice;
      final halfHeight =
          (sliderTheme.trackHeight ?? 2) / 2 + 2 + (active ? 1 : 0);
      final range = sliceRect(slice);
      final span = Rect.fromCenter(
        center: range.center,
        width: range.width,
        height: halfHeight * 2,
      );
      final selected = slice == selectedSlice;
      final roundedSpan = RRect.fromRectAndRadius(
        span,
        const Radius.circular(2),
      );
      context.canvas.save();
      context.canvas.clipPath(
        Path.combine(
          PathOperation.difference,
          Path()..addRRect(roundedSpan),
          paintedSlices,
        ),
      );
      paintTrack(sliderTheme.copyWith(trackHeight: halfHeight * 2));
      context.canvas.restore();
      paintedSlices.addRRect(roundedSpan);
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
