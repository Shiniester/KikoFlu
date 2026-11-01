import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/unified_search_history_provider.dart';
import 'package:kikoeru_flutter/src/widgets/search_filter_panel.dart';
import 'package:kikoeru_flutter/src/widgets/search_history_section.dart';

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

Widget _header(BuildContext context, Widget filterButton) =>
    Row(children: [const Spacer(), filterButton]);

void main() {
  testWidgets('selected filters remain visible when controls collapse', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const SearchFilterPanel(
          headerBuilder: _header,
          selected: Text('Selected condition'),
          filters: Text('Filter options'),
        ),
      ),
    );

    expect(find.text('Selected condition'), findsOneWidget);
    expect(find.text('Filter options'), findsNothing);
    await tester.tap(find.byTooltip('Filter'));
    await tester.pump();
    expect(find.text('Filter options'), findsOneWidget);
    await tester.tap(find.byTooltip('Filter'));
    await tester.pump();
    expect(find.text('Filter options'), findsNothing);
    expect(find.text('Selected condition'), findsOneWidget);
  });

  for (final width in [320.0, 840.0]) {
    testWidgets('filter panel fits a $width logical-pixel window', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _app(
          SearchFilterPanel(
            headerBuilder: _header,
            selected: const Wrap(children: [Chip(label: Text('Selected'))]),
            filters: Wrap(
              spacing: 8,
              children: [
                for (var index = 0; index < 6; index++)
                  Chip(label: Text('Filter $index')),
              ],
            ),
          ),
          textScale: 1.6,
        ),
      );
      await tester.tap(find.byTooltip('Filter'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
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
