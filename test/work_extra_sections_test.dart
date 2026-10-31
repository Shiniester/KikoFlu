import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_extra_sections.dart';

Widget _testApp(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    ),
  );
}

const _editions = [
  OtherLanguageEdition(
    id: 10,
    lang: 'ja',
    title: 'Japanese Edition',
    sourceId: 'RJ010',
    isOriginal: true,
    sourceType: 'dlsite',
  ),
  OtherLanguageEdition(
    id: 11,
    lang: 'en',
    title: 'English Edition',
    sourceId: 'RJ011',
    isOriginal: false,
    sourceType: 'dlsite',
  ),
];

void main() {
  testWidgets('WorkReleaseDateSection renders localized label and date',
      (tester) async {
    await tester.pumpWidget(
      _testApp(
        const WorkReleaseDateSection(
          release: '2024-01-02T15:30:00Z',
        ),
      ),
    );

    expect(find.byTooltip('Release Date'), findsOneWidget);
    expect(find.text('Release Date'), findsOneWidget);
    expect(find.text('2024-01-02'), findsOneWidget);
    expect(find.byIcon(Icons.calendar_today_outlined), findsNothing);
    expect(
      tester.getCenter(find.text('Release Date')).dy,
      closeTo(tester.getCenter(find.text('2024-01-02')).dy, 0.1),
    );
    expect(
      tester.getTopRight(find.text('Release Date')).dx,
      lessThan(tester.getTopLeft(find.text('2024-01-02')).dx),
    );
  });

  testWidgets('WorkReleaseDateSection hides when release is missing',
      (tester) async {
    await tester.pumpWidget(
      _testApp(const WorkReleaseDateSection()),
    );

    expect(find.byTooltip('Release Date'), findsNothing);
  });

  testWidgets('OtherLanguageEditionsSection renders chips and handles taps',
      (tester) async {
    OtherLanguageEdition? selectedEdition;

    await tester.pumpWidget(
      _testApp(
        OtherLanguageEditionsSection(
          editions: _editions,
          onEditionSelected: (edition) => selectedEdition = edition,
        ),
      ),
    );

    expect(find.text('Other Editions'), findsOneWidget);
    expect(find.text('「ja」'), findsOneWidget);
    expect(find.text('「en」'), findsOneWidget);
    expect(find.byIcon(Icons.translate), findsNWidgets(2));

    await tester.tap(find.text('「en」'));

    expect(selectedEdition, _editions.last);
  });

  testWidgets('OtherLanguageEditionsSection hides without editions',
      (tester) async {
    await tester.pumpWidget(
      _testApp(const OtherLanguageEditionsSection(editions: [])),
    );

    expect(find.text('Other Editions'), findsNothing);
    expect(find.byIcon(Icons.translate), findsNothing);
  });
}
