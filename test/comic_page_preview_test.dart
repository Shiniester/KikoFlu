import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_page_preview.dart';

final _png = Uint8List.fromList(
  img.encodePng(img.Image(width: 512, height: 768)),
);

Widget _host({
  required int pageCount,
  required int initialPage,
  required Future<Uint8List> Function(int) loadImage,
  required ValueChanged<Future<int?>> onOpened,
  ValueChanged<int>? onSelected,
}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            key: const ValueKey('open-preview'),
            onPressed: () {
              onOpened(
                showModalBottomSheet<int>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (context) => DraggableScrollableSheet(
                    expand: false,
                    initialChildSize: .7,
                    minChildSize: .35,
                    maxChildSize: .95,
                    builder: (context, controller) => ComicPagePreview(
                      pageCount: pageCount,
                      initialPage: initialPage,
                      title: 'Raw chapter title',
                      scrollController: controller,
                      loadImage: loadImage,
                      onSelected: (index) {
                        onSelected?.call(index);
                        Navigator.of(context).pop(index);
                      },
                    ),
                  ),
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpFrames(WidgetTester tester, [int count = 6]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpNativeFrame(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _pumpNativeFrames(WidgetTester tester, [int count = 4]) async {
  for (var i = 0; i < count; i++) {
    await _pumpNativeFrame(tester);
  }
}

Future<void> _pumpUntilImage(WidgetTester tester, Finder image) async {
  for (var i = 0; i < 30 && image.evaluate().isEmpty; i++) {
    await _pumpNativeFrame(tester);
  }
  expect(image, findsOneWidget);
}

Future<void> _closePreview(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('comic-page-preview-close')));
  await _pumpFrames(tester, 4);
}

void main() {
  testWidgets('keeps every active thumbnail loaded in a tall desktop sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final requests = <int, int>{};
    await tester.pumpWidget(
      _host(
        pageCount: 150,
        initialPage: 0,
        loadImage: (index) async {
          requests.update(index, (count) => count + 1, ifAbsent: () => 1);
          return _png;
        },
        onOpened: (_) {},
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-preview')));
    await _pumpFrames(tester);
    for (var frame = 0; frame < 200; frame++) {
      await _pumpNativeFrame(tester);
      if (requests.length > 64 &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    expect(requests.length, greaterThan(64));
    expect(find.byType(Image).evaluate().length, greaterThan(64));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(requests.values, everyElement(1));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _closePreview(tester);
  });

  testWidgets('starts at the selected middle page with at most three loads', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final requests = <int, Completer<Uint8List>>{};
    var loading = 0;
    var maxLoading = 0;
    int? selected;
    Future<int?>? sheetResult;
    await tester.pumpWidget(
      _host(
        pageCount: 100,
        initialPage: 62,
        loadImage: (index) {
          loading++;
          if (loading > maxLoading) maxLoading = loading;
          final request = Completer<Uint8List>();
          requests[index] = request;
          return request.future.whenComplete(() => loading--);
        },
        onOpened: (result) => sheetResult = result,
        onSelected: (index) => selected = index,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-preview')));
    await _pumpFrames(tester);

    expect(find.text('Raw chapter title'), findsOneWidget);
    expect(requests, isNotEmpty);
    expect(requests.keys, isNot(contains(0)));
    expect(requests.length, lessThan(100));
    expect(requests.length, 3);
    expect(requests.keys.first, 62);
    expect(maxLoading, lessThanOrEqualTo(3));

    final pageTile = find.byKey(const ValueKey('comic-page-preview-62'));
    expect(pageTile, findsOneWidget);
    final viewport = tester.getRect(find.byType(GridView));
    expect(viewport.overlaps(tester.getRect(pageTile)), isTrue);
    final semantics = tester.getSemantics(find.bySemanticsLabel('Preview 63'));
    expect(semantics.flagsCollection.isSelected, Tristate.isTrue);
    await tester.tap(pageTile);
    await tester.pump();
    expect(selected, isNull);

    for (
      var attempt = 0;
      attempt < 10 && !requests.containsKey(62);
      attempt++
    ) {
      for (final request in requests.values) {
        if (!request.isCompleted) request.complete(_png);
      }
      await _pumpNativeFrames(tester, 4);
    }
    final selectedPageRequest = requests[62];
    expect(selectedPageRequest, isNotNull);
    if (!selectedPageRequest!.isCompleted) selectedPageRequest.complete(_png);
    await _pumpUntilImage(
      tester,
      find.descendant(of: pageTile, matching: find.byType(Image)),
    );
    final image = tester.widget<Image>(
      find.descendant(of: pageTile, matching: find.byType(Image)),
    );
    final thumbnail = img.decodePng((image.image as MemoryImage).bytes)!;
    expect(thumbnail.height, lessThanOrEqualTo(140));
    expect(thumbnail.width / thumbnail.height, closeTo(2 / 3, .02));
    await tester.tap(pageTile);
    await _pumpFrames(tester, 4);

    expect(selected, 62);
    expect(maxLoading, lessThanOrEqualTo(3));
    expect(await sheetResult!, 62);
  });

  testWidgets('shows retry after failure and selects after retry succeeds', (
    tester,
  ) async {
    var attempts = 0;
    int? selected;
    Future<int?>? sheetResult;
    await tester.pumpWidget(
      _host(
        pageCount: 1,
        initialPage: 0,
        loadImage: (_) async {
          attempts++;
          if (attempts == 1) throw StateError('image failed');
          return _png;
        },
        onOpened: (result) => sheetResult = result,
        onSelected: (index) => selected = index,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-preview')));
    await _pumpFrames(tester);

    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('comic-page-preview-0')));
    await _pumpFrames(tester);

    expect(attempts, 2);
    await _pumpUntilImage(tester, find.byType(Image));
    await tester.tap(find.byKey(const ValueKey('comic-page-preview-0')));
    await _pumpFrames(tester, 4);
    expect(selected, 0);
    expect(await sheetResult!, 0);
  });

  testWidgets('keeps compact and expanded sheet widths free of overflow', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    Future<int?>? sheetResult;
    await tester.pumpWidget(
      _host(
        pageCount: 40,
        initialPage: 19,
        loadImage: (_) async => _png,
        onOpened: (result) => sheetResult = result,
      ),
    );

    for (final size in [const Size(320, 640), const Size(1000, 800)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.tap(find.byKey(const ValueKey('open-preview')));
      await _pumpFrames(tester);
      expect(tester.takeException(), isNull);
      await _closePreview(tester);
      expect(await sheetResult!, isNull);
    }
  });

  testWidgets('closing stops queued pages from starting', (tester) async {
    final requests = <int, Completer<Uint8List>>{};
    Future<int?>? sheetResult;
    await tester.pumpWidget(
      _host(
        pageCount: 100,
        initialPage: 70,
        loadImage: (index) {
          final request = Completer<Uint8List>();
          requests[index] = request;
          return request.future;
        },
        onOpened: (result) => sheetResult = result,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-preview')));
    await _pumpFrames(tester);
    final startedBeforeClose = requests.length;
    expect(startedBeforeClose, 3);

    await tester.tap(find.byKey(const ValueKey('comic-page-preview-close')));
    requests.values.first.complete(_png);
    await _pumpNativeFrame(tester);
    expect(requests.length, startedBeforeClose);
    await _pumpFrames(tester, 4);
    expect(await sheetResult!, isNull);
    for (final request in requests.values) {
      if (!request.isCompleted) request.complete(_png);
    }
    await _pumpFrames(tester, 2);
    expect(requests.length, startedBeforeClose);
  });
}
