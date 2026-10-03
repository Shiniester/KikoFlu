import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_palette_background.dart';

const _boundaryKey = ValueKey('background-test-boundary');

LinearGradient _gradient(Color color) => LinearGradient(colors: [color, color]);

Future<void> _pumpBackground(
  WidgetTester tester,
  Color color, {
  Duration duration = const Duration(milliseconds: 280),
  Size size = const Size(64, 64),
}) => tester.pumpWidget(
  MaterialApp(
    home: Center(
      child: RepaintBoundary(
        key: _boundaryKey,
        child: SizedBox.fromSize(
          size: size,
          child: PlayerPaletteBackground(
            gradient: _gradient(color),
            duration: duration,
          ),
        ),
      ),
    ),
  ),
);

Future<Color> _paintedColor(
  WidgetTester tester, {
  Offset sample = Offset.zero,
}) async => (await tester.runAsync(() async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  final image = await boundary.toImage();
  try {
    final pixels = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    final offset = (sample.dy.toInt() * image.width + sample.dx.toInt()) * 4;
    return Color.fromARGB(
      pixels.getUint8(offset + 3),
      pixels.getUint8(offset),
      pixels.getUint8(offset + 1),
      pixels.getUint8(offset + 2),
    );
  } finally {
    image.dispose();
  }
}))!;

void main() {
  testWidgets('palette remains live through an interrupted transition', (
    tester,
  ) async {
    await _pumpBackground(tester, const Color(0xffff0000));
    expect(await _paintedColor(tester), const Color(0xffff0000));
    await _pumpBackground(tester, const Color(0xff0000ff));
    await tester.pump(const Duration(milliseconds: 140));
    final middle = await _paintedColor(tester);
    expect(middle, isNot(const Color(0xffff0000)));
    expect(middle, isNot(const Color(0xff0000ff)));
    await _pumpBackground(tester, const Color(0xff00ff00));
    expect(await _paintedColor(tester), middle);
    await tester.pumpAndSettle();
    expect(await _paintedColor(tester), const Color(0xff00ff00));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion replaces the settled texture immediately', (
    tester,
  ) async {
    await _pumpBackground(
      tester,
      const Color(0xffff0000),
      duration: Duration.zero,
    );
    await _pumpBackground(
      tester,
      const Color(0xff0000ff),
      duration: Duration.zero,
    );
    expect(await _paintedColor(tester), const Color(0xff0000ff));
  });

  testWidgets('settled texture follows viewport size and pixel ratio', (
    tester,
  ) async {
    await _pumpBackground(tester, const Color(0xffff0000));
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpBackground(
      tester,
      const Color(0xff0000ff),
      size: const Size(96, 128),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(PlayerPaletteBackground)),
      const Size(96, 128),
    );
    expect(await _paintedColor(tester), const Color(0xff0000ff));
    expect(tester.takeException(), isNull);
  });

  testWidgets('resize refreshes a settled gradient without a palette change', (
    tester,
  ) async {
    const gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xffff0000), Color(0xff0000ff)],
    );
    Future<void> mount(Size size, {bool direct = false}) => tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: _boundaryKey,
            child: SizedBox.fromSize(
              size: size,
              child: direct
                  ? const DecoratedBox(
                      decoration: BoxDecoration(gradient: gradient),
                    )
                  : const PlayerPaletteBackground(
                      gradient: gradient,
                      duration: Duration.zero,
                    ),
            ),
          ),
        ),
      ),
    );
    await mount(const Size(64, 64));
    await mount(const Size(96, 128));
    final resized = await _paintedColor(tester, sample: const Offset(24, 96));
    await mount(const Size(96, 128), direct: true);
    final reference = await _paintedColor(tester, sample: const Offset(24, 96));
    expect(resized, reference);
  });
}
