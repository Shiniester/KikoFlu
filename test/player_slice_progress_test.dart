import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_slice.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_slice_progress.dart';

const _boundaryKey = ValueKey('slice-progress-boundary');
const _activeColor = Color(0xff334499);
const _sliceColor = Color(0xffb85b25);
const _inactiveColor = Color(0x40000000);
const _disabledActiveColor = Color(0xff666666);
const _disabledInactiveColor = Color(0x20000000);
const _slices = [
  AudioSlice(startMs: 20000, endMs: 40000),
  AudioSlice(startMs: 60000, endMs: 80000),
];

Color _onWhite(Color color) =>
    Color(Color.alphaBlend(color, Colors.white).toARGB32());

Future<void> _pumpProgress(
  WidgetTester tester, {
  required TextDirection direction,
  required bool onlySlices,
  bool enabled = true,
  List<AudioSlice> slices = _slices,
  Duration duration = const Duration(seconds: 100),
  double value = 0.7,
  double trackHeight = 4,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: direction,
        child: Center(
          child: RepaintBoundary(
            key: _boundaryKey,
            child: Material(
              color: Colors.white,
              child: SizedBox(
                width: 300,
                height: 32,
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: trackHeight,
                    padding: EdgeInsets.zero,
                    thumbShape: SliderComponentShape.noThumb,
                    overlayShape: SliderComponentShape.noOverlay,
                    activeTrackColor: _activeColor,
                    inactiveTrackColor: _inactiveColor,
                    disabledActiveTrackColor: _disabledActiveColor,
                    disabledInactiveTrackColor: _disabledInactiveColor,
                    trackShape: PlayerUniformSliderTrackShape(
                      sliceColor: _sliceColor,
                      slices: slices,
                      duration: duration,
                      onlySlices: onlySlices,
                    ),
                  ),
                  child: Slider(
                    value: value,
                    onChanged: enabled ? (_) {} : null,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<List<Color>> _paintedColors(
  WidgetTester tester,
  List<Offset> samples,
) async => (await tester.runAsync(() async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  final image = await boundary.toImage();
  try {
    final pixels = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    return samples.map((sample) {
      final offset = (sample.dy.toInt() * image.width + sample.dx.toInt()) * 4;
      return Color.fromARGB(
        pixels.getUint8(offset + 3),
        pixels.getUint8(offset),
        pixels.getUint8(offset + 1),
        pixels.getUint8(offset + 2),
      );
    }).toList();
  } finally {
    image.dispose();
  }
}))!;

void main() {
  for (final direction in TextDirection.values) {
    for (final onlySlices in [false, true]) {
      for (final enabled in [true, false]) {
        testWidgets(
          'slices use distinct colors at the same height with $direction, onlySlices=$onlySlices, enabled=$enabled',
          (tester) async {
            await _pumpProgress(
              tester,
              direction: direction,
              onlySlices: onlySlices,
              enabled: enabled,
            );
            Offset point(double fraction, [double y = 16]) => Offset(
              300 * (direction == TextDirection.ltr ? fraction : 1 - fraction),
              y,
            );

            final active = enabled ? _activeColor : _disabledActiveColor;
            final inactive = _onWhite(
              enabled ? _inactiveColor : _disabledInactiveColor,
            );
            final sliceActive = _onWhite(
              enabled ? _sliceColor : _sliceColor.withValues(alpha: 0.38),
            );
            final sliceInactive = _onWhite(
              _sliceColor.withValues(alpha: enabled ? 0.3 : 0.12),
            );
            expect(
              await _paintedColors(tester, [
                point(0.1),
                point(0.3),
                point(0.3, 14),
                point(0.5),
                point(0.65),
                point(0.65, 14),
                point(0.695),
                point(0.705),
                point(0.75),
                point(0.75, 14),
                point(0.9),
                for (final fraction in [0.1, 0.3, 0.65, 0.75]) ...[
                  point(fraction, 13),
                  point(fraction, 18),
                ],
              ]),
              [
                onlySlices ? inactive : active,
                sliceActive,
                sliceActive,
                onlySlices ? inactive : active,
                sliceActive,
                sliceActive,
                sliceActive,
                sliceInactive,
                sliceInactive,
                sliceInactive,
                inactive,
                ...List.filled(8, Colors.white),
              ],
            );
          },
        );
      }
    }

    testWidgets('short slices stay visible on a long track with $direction', (
      tester,
    ) async {
      final inactive = _onWhite(_sliceColor.withValues(alpha: 0.3));
      for (final value in [0.25, 0.75]) {
        await _pumpProgress(
          tester,
          direction: direction,
          onlySlices: false,
          duration: const Duration(hours: 1),
          slices: const [
            AudioSlice(startMs: 0, endMs: 1000),
            AudioSlice(startMs: 1800000, endMs: 1801000),
            AudioSlice(startMs: 1801000, endMs: 1802000),
            AudioSlice(startMs: 3599000, endMs: 3600000),
          ],
          value: value,
        );
        final middle = value < 0.5 ? inactive : _sliceColor;
        expect(
          await _paintedColors(tester, [
            for (final x in [1.0, 150.0, 298.0])
              for (final y in [15.0, 16.0])
                Offset(direction == TextDirection.ltr ? x : 299 - x, y),
          ]),
          [_sliceColor, _sliceColor, middle, middle, inactive, inactive],
        );
      }
    });

    for (final onlySlices in [false, true]) {
      testWidgets(
        'progress and slice ends share rounded caps with $direction, onlySlices=$onlySlices',
        (tester) async {
          await _pumpProgress(
            tester,
            direction: direction,
            onlySlices: onlySlices,
            trackHeight: 8,
          );
          Offset point(double x, double y) =>
              Offset(direction == TextDirection.ltr ? x : 299 - x, y);
          final inactive = _onWhite(_inactiveColor);
          final sliceInactive = _onWhite(_sliceColor.withValues(alpha: 0.3));
          expect(
            await _paintedColors(tester, [
              point(209, 12),
              point(207, 14),
              point(239, 12),
              point(237, 14),
            ]),
            [sliceInactive, _sliceColor, inactive, sliceInactive],
          );
        },
      );
    }
  }

  testWidgets('paused position in a gap does not paint slice progress', (
    tester,
  ) async {
    await _pumpProgress(
      tester,
      direction: TextDirection.ltr,
      onlySlices: true,
      value: 0.5,
    );
    expect(
      await _paintedColors(tester, const [
        Offset(149, 16),
        Offset(150, 16),
        Offset(151, 16),
      ]),
      List.filled(3, Color.alphaBlend(_inactiveColor, Colors.white)),
    );
  });

  testWidgets('only slices still shows full progress when no slices exist', (
    tester,
  ) async {
    await _pumpProgress(
      tester,
      direction: TextDirection.ltr,
      onlySlices: true,
      slices: const [],
    );
    expect(
      await _paintedColors(tester, const [Offset(150, 16), Offset(270, 16)]),
      [_activeColor, Color.alphaBlend(_inactiveColor, Colors.white)],
    );
  });
}
