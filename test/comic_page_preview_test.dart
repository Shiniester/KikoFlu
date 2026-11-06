import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_page_preview.dart';
import 'package:kikoeru_flutter/src/widgets/responsive_dialog.dart';

final _png = Uint8List.fromList(
  img.encodePng(img.Image(width: 512, height: 768)),
);

Widget _host({
  required int pageCount,
  required int initialPage,
  required Future<Uint8List> Function(int) loadImage,
  required ValueChanged<Future<int?>> onOpened,
  ValueChanged<int>? onSelected,
  bool responsive = false,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            key: const ValueKey('open-preview'),
            onPressed: () {
              Widget builder(BuildContext context) => DraggableScrollableSheet(
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
              );
              onOpened(
                responsive
                    ? showResponsiveBottomSheet<int>(
                        context: context,
                        builder: builder,
                      )
                    : showModalBottomSheet<int>(
                        context: context,
                        isScrollControlled: true,
                        useSafeArea: true,
                        builder: builder,
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
  for (final responsive in [false, true]) {
    testWidgets(
      'preview waits for entry motion before loading (responsive=$responsive)',
      (tester) async {
        final requests = <int, Completer<Uint8List>>{};
        await tester.pumpWidget(
          _host(
            pageCount: 100,
            initialPage: 62,
            responsive: responsive,
            loadImage: (index) =>
                (requests[index] = Completer<Uint8List>()).future,
            onOpened: (_) {},
          ),
        );
        await tester.tap(find.byKey(const ValueKey('open-preview')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        final route = ModalRoute.of(
          tester.element(find.byType(ComicPagePreview)),
        )!;
        expect(route.animation!.status, AnimationStatus.forward);
        expect(requests, isEmpty);
        await _pumpFrames(tester);
        expect(requests.keys.first, 62);
        expect(requests.length, 3);
        await _closePreview(tester);
        for (final request in requests.values) {
          request.complete(_png);
        }
        await _pumpNativeFrames(tester);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'preview resumes image work after a cancelled close drag (responsive=$responsive)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final requests = <int, Completer<Uint8List>>{};
        await tester.pumpWidget(
          _host(
            pageCount: 100,
            initialPage: 0,
            responsive: responsive,
            loadImage: (index) =>
                (requests[index] = Completer<Uint8List>()).future,
            onOpened: (_) {},
          ),
        );
        await tester.tap(find.byKey(const ValueKey('open-preview')));
        await _pumpFrames(tester);
        expect(requests.length, 3);
        final route = ModalRoute.of(
          tester.element(find.byType(ComicPagePreview)),
        )!;
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('Raw chapter title')),
        );
        await gesture.moveBy(
          const Offset(0, 20),
          timeStamp: const Duration(milliseconds: 100),
        );
        await gesture.moveBy(
          const Offset(0, 50),
          timeStamp: const Duration(milliseconds: 300),
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(route.animation!.value, lessThan(1));
        await gesture.up(timeStamp: const Duration(milliseconds: 500));
        await _pumpFrames(tester);
        expect(route.isCurrent, isTrue);
        expect(route.animation!.status, AnimationStatus.completed);
        for (final request in requests.values) {
          request.complete(_png);
        }
        await _pumpUntilImage(
          tester,
          find.descendant(
            of: find.byKey(const ValueKey('comic-page-preview-0')),
            matching: find.byType(RawImage),
          ),
        );
        await _closePreview(tester);
        for (final request in requests.values) {
          if (!request.isCompleted) request.complete(_png);
        }
        await _pumpNativeFrames(tester);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'preview skips decoding late bytes while closing (responsive=$responsive)',
      (tester) async {
        final requests = <Completer<Uint8List>>[];
        await tester.pumpWidget(
          _host(
            pageCount: 100,
            initialPage: 0,
            responsive: responsive,
            loadImage: (_) {
              final request = Completer<Uint8List>();
              requests.add(request);
              return request.future;
            },
            onOpened: (_) {},
          ),
        );
        await tester.tap(find.byKey(const ValueKey('open-preview')));
        await _pumpFrames(tester);
        expect(requests.length, 3);
        final previousOnCreate = ui.Image.onCreate;
        var created = 0;
        ui.Image.onCreate = (image) {
          created++;
          previousOnCreate?.call(image);
        };
        addTearDown(() => ui.Image.onCreate = previousOnCreate);
        if (responsive) {
          await tester.tapAt(const Offset(4, 4));
        } else {
          await tester.binding.handlePopRoute();
        }
        await tester.pump();
        for (final request in requests) {
          request.complete(_png);
        }
        await _pumpNativeFrames(tester);
        expect(created, 0);
        expect(requests.length, 3);
        expect(find.byType(ComicPagePreview), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('preview starts loading with reduced motion', (tester) async {
    final requests = <Completer<Uint8List>>[];
    await tester.pumpWidget(
      _host(
        pageCount: 10,
        initialPage: 0,
        responsive: true,
        disableAnimations: true,
        loadImage: (_) {
          final request = Completer<Uint8List>();
          requests.add(request);
          return request.future;
        },
        onOpened: (_) {},
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-preview')));
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump();
    }
    expect(
      ModalRoute.of(
        tester.element(find.byType(ComicPagePreview)),
      )!.animation!.status,
      AnimationStatus.completed,
    );
    expect(requests.length, 3);
    await _closePreview(tester);
    for (final request in requests) {
      request.complete(_png);
    }
    await _pumpNativeFrames(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet preview enlarges tiles and locates the selected page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final requests = <int, Completer<Uint8List>>{};
    await tester.pumpWidget(
      _host(
        pageCount: 100,
        initialPage: 62,
        loadImage: (index) => (requests[index] = Completer<Uint8List>()).future,
        onOpened: (_) {},
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-preview')));
    await _pumpFrames(tester);
    final tile = find.byKey(const ValueKey('comic-page-preview-62'));
    expect(tester.getSize(tile).height, 240);
    expect(tester.getSize(tile).width, greaterThanOrEqualTo(160));
    expect(
      tester.getRect(find.byType(GridView)).overlaps(tester.getRect(tile)),
      isTrue,
    );
    expect(requests.keys.first, 62);
    expect(requests.length, lessThanOrEqualTo(3));
    await _closePreview(tester);
    for (final request in requests.values) {
      request.complete(_png);
    }
    await _pumpNativeFrames(tester);
  });

  testWidgets('keeps every active thumbnail loaded in a tall desktop sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 8000);
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
    expect(find.byType(RawImage).evaluate().length, greaterThan(64));
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
    expect(semantics.flagsCollection.isSelected, ui.Tristate.isTrue);
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
      find.descendant(of: pageTile, matching: find.byType(RawImage)),
    );
    final image = tester.widget<RawImage>(
      find.descendant(of: pageTile, matching: find.byType(RawImage)),
    );
    final thumbnail = image.image!;
    expect(thumbnail.height, lessThanOrEqualTo(140));
    expect(thumbnail.width / thumbnail.height, closeTo(2 / 3, .02));
    await tester.tap(pageTile);
    await _pumpFrames(tester, 4);

    expect(selected, 62);
    expect(maxLoading, lessThanOrEqualTo(3));
    expect(await sheetResult!, 62);
    expect(thumbnail.debugDisposed, isTrue);
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
    await _pumpUntilImage(tester, find.byType(RawImage));
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
