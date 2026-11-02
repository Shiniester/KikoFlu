import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/comics/comic_models.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_settings_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_widgets.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets('long comic errors scroll to a usable retry action', (
    tester,
  ) async {
    _setViewport(tester, const Size(390, 320));
    var retries = 0;
    final message = List.generate(
      40,
      (index) => 'Source request failed at page $index.',
    ).join('\n');
    await tester.pumpWidget(
      _app(
        ComicErrorView(
          error: ComicSourceException(message),
          retry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final errorView = find.byType(ComicErrorView);
    final retry = find.text(S.of(tester.element(errorView)).retry);
    expect(tester.takeException(), isNull);
    expect(tester.getRect(retry).bottom, greaterThan(320));

    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    expect(tester.getRect(retry).bottom, lessThanOrEqualTo(320));
    await tester.tap(retry);
    await tester.pump();

    expect(retries, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('login settings action scrolls into view and opens settings', (
    tester,
  ) async {
    _setViewport(tester, const Size(390, 180));
    await tester.pumpWidget(
      _app(
        ComicErrorView(
          error: const ComicSourceException('', loginRequired: true),
          retry: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final errorView = find.byType(ComicErrorView);
    final settings = find.text(S.of(tester.element(errorView)).comicSettings);
    expect(tester.takeException(), isNull);
    expect(tester.getRect(settings).bottom, greaterThan(180));

    await tester.ensureVisible(settings);
    await tester.pumpAndSettle();
    expect(tester.getRect(settings).bottom, lessThanOrEqualTo(180));
    await tester.tap(settings);
    await tester.pumpAndSettle();

    expect(find.byType(ComicSettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short comic errors remain vertically centered', (tester) async {
    _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      _app(
        const ComicErrorView(
          error: ComicSourceException('Short source failure'),
          retry: _noop,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final column = find.descendant(
      of: find.byType(ComicErrorView),
      matching: find.byType(Column),
    );
    expect(
      tester.getRect(column).center.dy,
      closeTo(tester.getRect(find.byType(Scaffold)).center.dy, 0.5),
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _app(Widget body) => ProviderScope(
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: Scaffold(body: body),
  ),
);

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void _noop() {}
