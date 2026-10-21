import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/models/sort_options.dart';
import 'package:kikoeru_flutter/src/utils/l10n_extensions.dart';
import 'package:kikoeru_flutter/src/widgets/responsive_dialog.dart';
import 'package:kikoeru_flutter/src/widgets/sort_dialog.dart';

Widget _testApp({
  required Size size,
  required ValueChanged<BuildContext> onContext,
}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Builder(
        builder: (context) {
          onContext(context);
          return const Scaffold(body: SizedBox.expand());
        },
      ),
    ),
  );
}

void main() {
  testWidgets('uses compact left-aligned sections across sort callers', (
    tester,
  ) async {
    late BuildContext context;
    SortOrder? selectedOrder;

    await tester.pumpWidget(
      _testApp(
        size: const Size(390, 844),
        onContext: (value) => context = value,
      ),
    );

    showDialog<void>(
      context: context,
      builder: (context) => CommonSortDialog(
        title: 'Sort Options',
        currentOption: SortOrder.updatedAt,
        currentDirection: SortDirection.desc,
        availableOptions: const [
          SortOrder.updatedAt,
          SortOrder.release,
          SortOrder.review,
          SortOrder.dlCount,
        ],
        onSort: (order, direction) => selectedOrder = order,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ResponsiveDialog), findsOneWidget);
    expect(find.byType(ResponsiveAlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('sort-field-section')), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Sort Field')).dx,
      lessThan(tester.getCenter(find.byType(ResponsiveDialog)).dx),
    );

    final tiles = find.byWidgetPredicate((widget) => widget is RadioListTile);
    expect(tiles, findsNWidgets(6));
    for (final element in tiles.evaluate()) {
      expect(
        tester.getSize(find.byElementPredicate((e) => e == element)).height,
        lessThanOrEqualTo(48),
      );
    }

    await tester.tap(find.text('Reviews'));
    await tester.pumpAndSettle();

    expect(selectedOrder, SortOrder.review);
    expect(find.byType(CommonSortDialog), findsNothing);
  });

  testWidgets('keeps the compact sections side by side in landscape', (
    tester,
  ) async {
    late BuildContext context;
    SortDirection? selectedDirection;

    await tester.pumpWidget(
      _testApp(
        size: const Size(900, 500),
        onContext: (value) => context = value,
      ),
    );

    showDialog<void>(
      context: context,
      builder: (context) => CommonSortDialog(
        currentOption: SortOrder.release,
        currentDirection: SortDirection.desc,
        availableOptions: const [SortOrder.release, SortOrder.dlCount],
        autoClose: false,
        onSort: (order, direction) => selectedDirection = direction,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sort Options'), findsOneWidget);
    final fieldLeft = tester
        .getTopLeft(find.byKey(const ValueKey('sort-field-section')))
        .dx;
    final directionLeft = tester
        .getTopLeft(find.byKey(const ValueKey('sort-direction-section')))
        .dx;
    expect(fieldLeft, lessThan(directionLeft));

    await tester.tap(find.text('Ascending'));
    await tester.pump();
    expect(selectedDirection, SortDirection.asc);
    expect(find.byType(CommonSortDialog), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(CommonSortDialog), findsNothing);
  });

  testWidgets('confirmation mode stages choices until confirmed once', (
    tester,
  ) async {
    late BuildContext context;
    var calls = 0;
    SortOrder? appliedOption;
    SortDirection? appliedDirection;
    AgeRating? appliedAgeRating;

    await tester.pumpWidget(
      _testApp(
        size: const Size(390, 844),
        onContext: (value) => context = value,
      ),
    );
    final s = S.of(context);

    Future<void> openDialog() async {
      showDialog<void>(
        context: context,
        builder: (dialogContext) => SortOptionsDialog<SortOrder>(
          currentOption: SortOrder.release,
          currentDirection: SortDirection.desc,
          currentAgeRating: AgeRating.all,
          availableOptions: const [SortOrder.release, SortOrder.review],
          availableAgeRatings: const [
            AgeRating.all,
            AgeRating.general,
            AgeRating.adult,
          ],
          labelBuilder: (option) => option.localizedLabel(dialogContext),
          onSort: (option, direction, ageRating) {
            calls++;
            appliedOption = option;
            appliedDirection = direction;
            appliedAgeRating = ageRating;
          },
          confirmChanges: true,
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> selectDifferentValues() async {
      await tester.ensureVisible(find.text(s.sortReviewCount));
      await tester.tap(find.text(s.sortReviewCount));
      await tester.pump();
      await tester.ensureVisible(find.text(s.sortAsc));
      await tester.tap(find.text(s.sortAsc));
      await tester.pump();
      await tester.ensureVisible(find.text(s.ageRatingGeneral));
      await tester.tap(find.text(s.ageRatingGeneral));
      await tester.pump();
    }

    await openDialog();
    expect(find.byKey(const ValueKey('sort-field-section')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sort-direction-section')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sort-age-rating-section')),
      findsOneWidget,
    );
    final fields = find.byKey(const ValueKey('sort-field-section'));
    expect(
      find.descendant(of: fields, matching: find.text(s.sortRandom)),
      findsNothing,
    );
    expect(
      find.descendant(of: fields, matching: find.text(s.sortNsfw)),
      findsNothing,
    );
    expect(find.text(s.ageRatingR15), findsNothing);
    expect(find.text('R18'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<AgeRating>), findsNothing);

    await selectDifferentValues();
    expect(calls, 0);
    await tester.tap(find.text(s.cancel));
    await tester.pumpAndSettle();
    expect(calls, 0);

    await openDialog();
    await selectDifferentValues();
    expect(calls, 0);
    await tester.tap(find.text(s.confirm));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(appliedOption, SortOrder.review);
    expect(appliedDirection, SortDirection.asc);
    expect(appliedAgeRating, AgeRating.general);

    await openDialog();
    await selectDifferentValues();
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('sort options fit in a compact portrait and landscape window', (
    tester,
  ) async {
    for (final size in [const Size(320, 640), const Size(844, 390)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late BuildContext context;
      await tester.pumpWidget(
        _testApp(size: size, onContext: (value) => context = value),
      );
      showDialog<void>(
        context: context,
        builder: (dialogContext) => SortOptionsDialog<SortOrder>(
          currentOption: SortOrder.release,
          currentDirection: SortDirection.desc,
          currentAgeRating: AgeRating.all,
          availableOptions: const [
            SortOrder.release,
            SortOrder.review,
            SortOrder.dlCount,
          ],
          labelBuilder: (option) => option.localizedLabel(dialogContext),
          onSort: (option, direction, ageRating) {},
          confirmChanges: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SortOptionsDialog<SortOrder>), findsOneWidget);
      final fieldSection = find.byKey(const ValueKey('sort-field-section'));
      final directionSection = find.byKey(
        const ValueKey('sort-direction-section'),
      );
      if (size.width < 600) {
        expect(
          tester.getTopLeft(fieldSection).dx,
          closeTo(tester.getTopLeft(directionSection).dx, 1),
        );
      } else {
        expect(
          tester.getTopLeft(fieldSection).dx,
          lessThan(tester.getTopLeft(directionSection).dx),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(S.of(context).cancel));
      await tester.pumpAndSettle();
    }
  });
}
