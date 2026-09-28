import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_cover_frame.dart';

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
