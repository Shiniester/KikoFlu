import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/cover_preview_dialog.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_visual_palette.dart';
import 'package:kikoeru_flutter/src/widgets/privacy_blur_cover.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('cover extension keeps a known source extension', () {
    expect(
      resolveCoverImageExtension(
        source: 'https://example.test/cover.webp?token=secret',
        bytes: Uint8List(0),
      ),
      'webp',
    );
  });

  test('cover extension detects bytes and falls back to jpeg', () {
    expect(
      resolveCoverImageExtension(
        bytes: Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]),
      ),
      'png',
    );
    expect(
      resolveCoverImageExtension(bytes: Uint8List.fromList([1, 2, 3])),
      'jpg',
    );
  });

  testWidgets('cover preview has no toolbar and single tap returns', (
    tester,
  ) async {
    await _pumpPreviewHost(tester);

    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.byIcon(Icons.save_alt), findsNothing);
    expect(find.byType(PrivacyBlurCover), findsOneWidget);
    final linear = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('cover-preview-linear-background')),
    );
    final radial = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('cover-preview-radial-background')),
    );
    expect(
      (linear.decoration as BoxDecoration).gradient,
      _previewPalette.backgroundGradient,
    );
    expect(
      (radial.decoration as BoxDecoration).gradient,
      _previewPalette.accentGradient,
    );

    await _tapPreviewCenter(tester);
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('cover-preview-background')),
      findsNothing,
    );
  });

  testWidgets('preview frame uses the decoded ratio inside 16 pixel margins', (
    tester,
  ) async {
    await _pumpPreviewHost(tester);

    final viewport = tester.getRect(
      find.byKey(const ValueKey('cover-preview-background')),
    );
    final frame = tester.getRect(
      find.byKey(const ValueKey('cover-preview-image-frame')),
    );
    expect(frame.width / frame.height, closeTo(4 / 3, 0.001));
    expect(frame.left - viewport.left, greaterThanOrEqualTo(16));
    expect(viewport.right - frame.right, greaterThanOrEqualTo(16));
    expect(frame.top - viewport.top, greaterThanOrEqualTo(16));
    expect(viewport.bottom - frame.bottom, greaterThanOrEqualTo(16));
    final clip = tester.widget<ClipRRect>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('cover-preview-image')),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(clip.borderRadius, BorderRadius.circular(12));
  });

  testWidgets('double tap zooms without closing the preview', (tester) async {
    await _pumpPreviewHost(tester);

    await _tapPreviewCenter(tester);
    await tester.pump(const Duration(milliseconds: 100));
    await _tapPreviewCenter(tester);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('cover-preview-background')),
      findsOneWidget,
    );
    final viewer = tester.widget<InteractiveViewer>(
      find.byKey(const ValueKey('cover-preview-interactive-viewer')),
    );
    expect(viewer.minScale, 1);
    expect(viewer.maxScale, 5);
    expect(viewer.clipBehavior, Clip.none);
    final listener = tester.widget<Listener>(
      find.byKey(const ValueKey('cover-preview-background')),
    );
    expect(listener.onPointerDown, isNotNull);
    expect(listener.onPointerUp, isNotNull);
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      closeTo(2.5, 0.001),
    );
  });

  testWidgets('pinch zoom uses the unclipped preview viewport', (tester) async {
    await _pumpPreviewHost(tester);

    final viewerFinder = find.byKey(
      const ValueKey('cover-preview-interactive-viewer'),
    );
    expect(tester.getSize(viewerFinder).shortestSide, greaterThan(40));
    final viewer = tester.widget<InteractiveViewer>(viewerFinder);
    final start = tester.getTopLeft(viewerFinder) + const Offset(20, 20);
    final left = await tester.createGesture();
    final right = await tester.createGesture();
    addTearDown(left.removePointer);
    addTearDown(right.removePointer);
    await left.down(start);
    await right.down(start + const Offset(10, 0));
    await tester.pump();
    await left.moveTo(start - const Offset(10, 0));
    await right.moveTo(start + const Offset(30, 0));
    await tester.pump();

    expect(viewer.clipBehavior, Clip.none);
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(1),
    );

    await left.up();
    await right.up();
    await tester.pumpAndSettle();
  });

  testWidgets('blank background returns from the preview', (tester) async {
    await _pumpPreviewHost(tester);

    final background = find.byKey(const ValueKey('cover-preview-background'));
    await tester.tapAt(tester.getTopLeft(background) + const Offset(8, 8));
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('cover-preview-background')),
      findsNothing,
    );
  });

  testWidgets('escape returns from the preview', (tester) async {
    await _pumpPreviewHost(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('cover-preview-background')),
      findsNothing,
    );
  });
}

const _previewPalette = PlayerVisualPalette(
  backgroundStart: Color(0xff102030),
  backgroundMiddle: Color(0xff304050),
  backgroundEnd: Color(0xff506070),
  foreground: Colors.white,
  secondaryForeground: Colors.white70,
  accent: Color(0xff8090a0),
  onAccent: Colors.black,
  panelColor: Color(0x20000000),
  panelStroke: Color(0x30000000),
);

Future<void> _pumpPreviewHost(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        initialRoute: '/preview',
        routes: {
          '/': (context) => const Scaffold(body: Text('host')),
          '/preview': (context) => const CoverPreviewDialog(
            localPath: 'assets/icons/app_icon_opaque.png',
            backgroundPalette: _previewPalette,
          ),
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapPreviewCenter(WidgetTester tester) {
  final background = find.byKey(const ValueKey('cover-preview-background'));
  return tester.tapAt(tester.getCenter(background));
}
