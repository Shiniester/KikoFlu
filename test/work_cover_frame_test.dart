import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_cover_frame.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_detail_responsive_layout.dart';

Widget _testApp(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  for (final (name, viewport, imageSize) in [
    ('tablet portrait', const Size(800, 1280), const Size(1200, 900)),
    ('tablet thumbnail', const Size(800, 1280), const Size(240, 180)),
    ('expanded portrait', const Size(1024, 1366), const Size(1200, 900)),
    ('compact portrait', const Size(390, 844), const Size(1200, 900)),
    ('landscape', const Size(1280, 800), const Size(1200, 900)),
    ('wide cover', const Size(800, 1280), const Size(1600, 900)),
    ('tall cover', const Size(800, 1280), const Size(900, 1200)),
  ]) {
    testWidgets('$name clips the visible cover at its image bounds', (
      tester,
    ) async {
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final image = await tester.runAsync(
        () => createTestImage(
          width: imageSize.width.toInt(),
          height: imageSize.height.toInt(),
        ),
      );
      addTearDown(image!.dispose);

      await tester.pumpWidget(
        _testApp(
          WorkDetailResponsiveLayout(
            coverBuilder: (_, isLandscape) => WorkCoverFrame(
              isLandscape: isLandscape,
              showSubtitleBadge: true,
              showAgeRating: true,
              age: 'R18',
              layers: [RawImage(image: image, fit: BoxFit.contain)],
            ),
            infoSliver: const SliverToBoxAdapter(child: Text('Work details')),
          ),
        ),
      );

      final cover = tester.getRect(find.byType(WorkCoverClip));
      final fitted = applyBoxFit(
        BoxFit.contain,
        Size(image.width.toDouble(), image.height.toDouble()),
        tester.getSize(find.byType(RawImage)),
      );
      final renderImage = tester.renderObject<RenderBox>(find.byType(RawImage));
      final visibleCover = MatrixUtils.transformRect(
        renderImage.getTransformTo(null),
        Alignment.center.inscribe(
          fitted.destination,
          Offset.zero & renderImage.size,
        ),
      );
      expect(cover, rectMoreOrLessEquals(visibleCover, epsilon: 0.01));
      final isLandscape = viewport.width > viewport.height;
      final expectedSize = applyBoxFit(
        BoxFit.contain,
        imageSize,
        Size(
          (isLandscape ? viewport.width * 0.4 : viewport.width) - 16,
          isLandscape ? viewport.height * 0.8 : 500,
        ),
      ).destination;
      expect(cover.width, closeTo(expectedSize.width, 0.01));
      expect(cover.height, closeTo(expectedSize.height, 0.01));
      expect(
        cover.center.dx,
        closeTo(viewport.width * (isLandscape ? 0.2 : 0.5), 0.01),
      );
      final clip = tester.widget<ClipRRect>(
        find.descendant(
          of: find.byType(WorkCoverClip),
          matching: find.byType(ClipRRect),
        ),
      );
      expect(clip.borderRadius, BorderRadius.circular(12));
      final ageBadge = tester.getRect(
        find.byKey(const ValueKey('work-cover-age-badge')),
      );
      final subtitleBadge = tester.getRect(
        find.byKey(const ValueKey('work-cover-subtitle-badge')),
      );
      expect(ageBadge.left, closeTo(cover.left + 12, 0.01));
      expect(ageBadge.bottom, closeTo(cover.bottom - 12, 0.01));
      expect(subtitleBadge.right, closeTo(cover.right - 12, 0.01));
      expect(subtitleBadge.bottom, closeTo(cover.bottom - 12, 0.01));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('renders cover layers with rounded corners and no Hero', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        const WorkCoverFrame(
          isLandscape: false,
          layers: [Center(child: Text('Cover Layer'))],
        ),
      ),
    );

    expect(find.byType(Hero), findsNothing);
    expect(find.text('Cover Layer'), findsOneWidget);
    expect(find.text('Subtitle'), findsNothing);
    final roundedClips = find
        .descendant(
          of: find.byType(WorkCoverClip),
          matching: find.byType(ClipRRect),
        )
        .evaluate()
        .map((element) => element.widget as ClipRRect)
        .where((clip) => clip.borderRadius == BorderRadius.circular(12));
    expect(roundedClips, isNotEmpty);
  });

  testWidgets('shows subtitle and age badges and handles tap', (tester) async {
    var tapCount = 0;

    await tester.pumpWidget(
      _testApp(
        WorkCoverFrame(
          isLandscape: true,
          showSubtitleBadge: true,
          showAgeRating: true,
          age: 'R18',
          onTap: () => tapCount++,
          layers: const [Center(child: Text('Cover Layer'))],
        ),
      ),
    );

    expect(find.text('Subtitle'), findsOneWidget);
    expect(find.byKey(const ValueKey('work-cover-age-badge')), findsOneWidget);

    final ageBadge = tester.getRect(
      find.byKey(const ValueKey('work-cover-age-badge')),
    );
    final subtitleBadge = tester.getRect(
      find.byKey(const ValueKey('work-cover-subtitle-badge')),
    );
    expect(ageBadge.bottom, subtitleBadge.bottom);
    expect(ageBadge.left, lessThan(subtitleBadge.left));

    await tester.tap(find.text('Cover Layer'));

    expect(tapCount, 1);
  });
}
