import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/pagination_bar.dart';

void main() {
  testWidgets('source page buttons without URLs render disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        theme: ThemeData(useMaterial3: true),
        home: const Scaffold(
          body: Center(
            child: PaginationBar(
              currentPage: 2,
              pageSize: 20,
              totalCount: null,
              jumpMaxPage: 8,
              hasMore: true,
              isLoading: false,
              onGoToPage: _ignorePage,
            ),
          ),
        ),
      ),
    );

    final l10n = await S.delegate.load(const Locale('en'));
    final previous = find.ancestor(
      of: find.text(l10n.previousPage),
      matching: find.byType(InkWell),
    );
    final next = find.ancestor(
      of: find.text(l10n.nextPage),
      matching: find.byType(InkWell),
    );
    expect(tester.widget<InkWell>(previous).onTap, isNull);
    expect(tester.widget<InkWell>(next).onTap, isNull);

    final theme = Theme.of(tester.element(find.byType(PaginationBar)));
    for (final label in [l10n.previousPage, l10n.nextPage]) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byType(Material),
      );
      expect(
        tester.widget<Material>(button.first).color,
        theme.colorScheme.surfaceContainerLow,
      );
    }
    expect(find.text(l10n.jumpTo), findsOneWidget);
  });
}

void _ignorePage(int _) {}
