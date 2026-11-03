import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/unified_search_history_provider.dart';
import 'package:kikoeru_flutter/src/widgets/search_history_section.dart';
import 'package:kikoeru_flutter/src/widgets/search_options_button.dart';

Widget _app(Widget child, {double textScale = 1}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: S.localizationsDelegates,
  supportedLocales: S.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('search options open without moving results and toggle closed', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Column(
          children: [
            Row(
              children: [
                Spacer(),
                SearchOptionsButton(
                  icon: Icons.tune,
                  tooltip: 'Filter',
                  child: Text('Filter options'),
                ),
              ],
            ),
            SizedBox(key: ValueKey('results'), height: 200),
          ],
        ),
      ),
    );

    final results = find.byKey(const ValueKey('results'));
    final position = tester.getTopLeft(results);
    expect(find.text('Filter options'), findsNothing);
    await tester.tap(find.byTooltip('Filter'));
    await tester.pumpAndSettle();
    expect(find.text('Filter options'), findsOneWidget);
    expect(tester.getTopLeft(results), position);
    await tester.tap(find.byTooltip('Filter'));
    await tester.pumpAndSettle();
    expect(find.text('Filter options'), findsNothing);
    await tester.tap(find.byTooltip('Filter'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Filter options'), findsNothing);
    expect(tester.getTopLeft(results), position);
  });

  testWidgets('search options reflect immediate changes and dismiss on back', (
    tester,
  ) async {
    var selected = false;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => SearchOptionsButton(
            icon: Icons.tune,
            tooltip: 'Filter',
            child: SwitchListTile(
              title: const Text('Subtitles'),
              value: selected,
              onChanged: (value) => setState(() => selected = value),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Filter'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(selected, isTrue);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNothing);
  });

  for (final width in [320.0, 840.0]) {
    testWidgets(
      'search options scroll at $width with a keyboard and large text',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 800);
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _app(
            SearchOptionsButton(
              icon: Icons.tune,
              tooltip: 'Filter',
              child: Column(
                children: [
                  for (var index = 0; index < 12; index++)
                    ListTile(title: Text('Filter $index')),
                ],
              ),
            ),
            textScale: 1.6,
          ),
        );
        await tester.tap(find.byTooltip('Filter'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Filter 11'));
        await tester.pumpAndSettle();
        expect(find.text('Filter 11').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('history removes one entry and confirms clearing', (
    tester,
  ) async {
    final entries = [
      UnifiedSearchHistoryEntry(
        id: 'one',
        context: const UnifiedSearchHistoryContext(
          contentType: 'video',
          entryScope: 'source-directory',
          source: 'legacy-unknown',
        ),
        payload: {'keyword': 'sample', 'legacy': true},
        timestamp: DateTime(2026),
      ),
    ];
    var removed = false;
    var cleared = false;
    await tester.pumpWidget(
      _app(
        SearchHistorySection(
          entries: entries,
          labelFor: (entry) => entry.payload['keyword']! as String,
          onSelect: (_) {},
          onRemove: (_) => removed = true,
          onClear: () => cleared = true,
          canPersist: false,
        ),
      ),
    );

    expect(find.text('Older searches (scope unknown)'), findsOneWidget);
    expect(
      find.text(
        'Search history cannot be saved. New entries remain only until the app closes.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Delete'));
    expect(removed, isTrue);
    await tester.tap(find.byTooltip('Clear Search History'));
    await tester.pumpAndSettle();
    expect(cleared, isFalse);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(cleared, isTrue);
  });
}
