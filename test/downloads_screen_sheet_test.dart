import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/widgets/download_fab.dart';

void main() {
  testWidgets(
    'downloads open in a compact bottom sheet and keep selection controls',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 780);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(_app());
      await tester.pump();
      await tester.tap(find.byTooltip('Download Tasks'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Download Tasks'), findsOneWidget);
      expect(find.text('No download tasks'), findsOneWidget);
      await tester.tap(find.byTooltip('Select'));
      await tester.pump();
      expect(find.text('0 selected'), findsOneWidget);
      expect(find.byTooltip('Select All'), findsOneWidget);
      expect(find.byTooltip('Deselect All'), findsOneWidget);
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(find.byTooltip('Resume'), findsOneWidget);
      expect(find.byTooltip('Delete'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      expect(find.text('0 selected'), findsNothing);
      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Download Tasks'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'downloads use the same responsive panel on wide landscape screens',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1024, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(_app());
      await tester.pump();
      await tester.tap(find.byTooltip('Download Tasks'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Download Tasks'), findsOneWidget);
      expect(find.text('No download tasks'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Download Tasks'), findsNothing);
    },
  );
}

Widget _app() => ProviderScope(
  overrides: [
    downloadSummaryProvider.overrideWith(
      (ref) => Stream.value(const DownloadTaskSummary.empty()),
    ),
    activeDownloadTaskIdsProvider.overrideWith(
      (ref) => Stream<List<String>>.value(const []),
    ),
  ],
  child: const MaterialApp(
    locale: Locale('en'),
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: Scaffold(
      floatingActionButton: DownloadFab(showDownloadButtonWhenIdle: true),
    ),
  ),
);
