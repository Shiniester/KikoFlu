import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/widgets/circle_chip.dart';
import 'package:kikoeru_flutter/src/widgets/metadata_search_chip.dart';
import 'package:kikoeru_flutter/src/widgets/tag_chip.dart';
import 'package:kikoeru_flutter/src/widgets/va_chip.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_metadata_sections.dart';

Widget _testApp(Widget child) {
  return MaterialApp(
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  );
}

const _work = Work(
  id: 1,
  title: 'Work',
  circleId: 10,
  name: 'Circle',
  vas: [Va(id: '20', name: 'VA')],
  tags: [Tag(id: 999999, name: 'Custom Tag')],
);
const _japaneseWork = Work(
  id: -1,
  title: 'Japanese work',
  circleId: 10,
  name: 'Japanese circle',
  vas: [Va(id: '20', name: 'Japanese VA')],
  tags: [Tag(id: 999999, name: 'Japanese Tag')],
);

void main() {
  testWidgets('WorkCreatorChipsSection renders circle and VA copy actions', (
    tester,
  ) async {
    final copied = <String>[];

    await tester.pumpWidget(
      _testApp(
        WorkCreatorChipsSection(
          work: _work,
          onCopy: (text, label) => copied.add('$label:$text'),
        ),
      ),
    );

    expect(find.text('Circle'), findsOneWidget);
    expect(find.text('VA'), findsOneWidget);
    expect(find.byType(CircleChip), findsOneWidget);
    expect(find.byType(VaChip), findsOneWidget);
    expect(
      tester.widget<CircleChip>(find.byType(CircleChip)).searchEnabled,
      isTrue,
    );
    expect(tester.widget<VaChip>(find.byType(VaChip)).searchEnabled, isTrue);

    await tester.longPress(find.text('Circle'));
    await tester.longPress(find.text('VA'));

    expect(copied.map((value) => value.split(':').last), ['Circle', 'VA']);
  });

  testWidgets('Japanese metadata chips search and keep long presses', (
    tester,
  ) async {
    final copied = <String>[];
    final tagActions = <String>[];

    await tester.pumpWidget(
      _testApp(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            WorkCreatorChipsSection(
              work: _japaneseWork,
              onCopy: (text, label) => copied.add('$label:$text'),
            ),
            WorkTagChipsSection(
              tags: _japaneseWork.tags,
              source: _japaneseWork.audioSource,
              onTagLongPress: (tag) => tagActions.add('long:${tag.name}'),
              onTagSecondaryTap: (tag) =>
                  tagActions.add('secondary:${tag.name}'),
            ),
          ],
        ),
      ),
    );

    final circleFinder = find.byType(CircleChip);
    final vaFinder = find.byType(VaChip);
    final tagFinder = find.byType(TagChip);
    expect(tester.widget<CircleChip>(circleFinder).searchEnabled, isTrue);
    expect(tester.widget<VaChip>(vaFinder).searchEnabled, isTrue);
    expect(tester.widget<TagChip>(tagFinder).searchEnabled, isTrue);
    final searchChips = tester.widgetList<MetadataSearchChip>(
      find.byType(MetadataSearchChip),
    );
    expect(
      searchChips.map((chip) => chip.source),
      everyElement(AudioSource.jpAsmr),
    );
    expect(searchChips.map((chip) => chip.searchParams), everyElement(isEmpty));
    expect(searchChips.map((chip) => chip.searchKeyword), [
      'Japanese circle',
      'Japanese VA',
      'Japanese Tag',
    ]);

    await tester.longPress(find.text('Japanese circle'));
    await tester.longPress(find.text('Japanese VA'));
    await tester.longPress(find.text('Japanese Tag'));
    await tester.tapAt(
      tester.getCenter(find.text('Japanese Tag')),
      buttons: kSecondaryMouseButton,
    );

    expect(copied.map((value) => value.split(':').last), [
      'Japanese circle',
      'Japanese VA',
    ]);
    expect(tagActions, ['long:Japanese Tag', 'secondary:Japanese Tag']);
  });

  testWidgets('WorkCreatorChipsSection hides when no creators exist', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        const WorkCreatorChipsSection(work: Work(id: 2, title: 'No creators')),
      ),
    );

    expect(find.byType(CircleChip), findsNothing);
    expect(find.byType(VaChip), findsNothing);
  });

  testWidgets('WorkTagChipsSection renders tag actions and add button', (
    tester,
  ) async {
    Tag? longPressedTag;
    Tag? secondaryTappedTag;
    var addCount = 0;

    await tester.pumpWidget(
      _testApp(
        WorkTagChipsSection(
          tags: _work.tags,
          onTagLongPress: (tag) => longPressedTag = tag,
          onTagSecondaryTap: (tag) => secondaryTappedTag = tag,
          onAddTag: () => addCount++,
        ),
      ),
    );

    expect(find.byType(TagChip), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);

    await tester.longPress(find.text('Custom Tag'));
    await tester.tap(find.byIcon(Icons.add));
    await tester.tapAt(
      tester.getCenter(find.text('Custom Tag')),
      buttons: kSecondaryMouseButton,
    );

    expect(longPressedTag?.name, 'Custom Tag');
    expect(secondaryTappedTag?.name, 'Custom Tag');
    expect(addCount, 1);
  });

  testWidgets('WorkTagChipsSection shows labeled add button when empty', (
    tester,
  ) async {
    var addCount = 0;

    await tester.pumpWidget(
      _testApp(WorkTagChipsSection(tags: const [], onAddTag: () => addCount++)),
    );

    expect(find.byType(TagChip), findsNothing);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.textContaining('Tag'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));

    expect(addCount, 1);
  });
}
