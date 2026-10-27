import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/utils/collection_grid_layout.dart';

void main() {
  testWidgets('card padding follows the window and preserves vertical insets', (
    tester,
  ) async {
    for (final size in [const Size(390, 844), const Size(1280, 800)]) {
      late EdgeInsets padding;
      final metrics = <CollectionGridMetrics>[];
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Builder(
              builder: (context) {
                padding = collectionCardPadding(
                  context,
                  padding: const EdgeInsetsDirectional.fromSTEB(50, 3, 60, 19),
                );
                for (final layout in LayoutType.values) {
                  metrics.add(
                    resolveCollectionGridMetrics(
                      context,
                      layoutType: layout,
                      availableWidth: 300,
                      availableHeight: 500,
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final horizontal = size.width > size.height ? 24.0 : 8.0;
      expect(padding, EdgeInsets.fromLTRB(horizontal, 3, horizontal, 19));
      for (final metric in metrics) {
        expect(metric.padding.left, horizontal);
        expect(metric.padding.right, horizontal);
      }
    }
  });

  testWidgets('list cover height matches four rendered title lines', (
    tester,
  ) async {
    final cases = [
      (style: const TextStyle(fontSize: 14, height: 1.3), scale: 1.0),
      (style: const TextStyle(fontSize: 18, height: 1.1), scale: 1.5),
    ];
    double? firstHeight;
    double? scaledHeight;

    for (final testCase in cases) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(390, 844),
              textScaler: TextScaler.linear(testCase.scale),
            ),
            child: Scaffold(
              body: Builder(
                builder: (context) {
                  final size = collectionListCoverSizeForTitle(
                    context,
                    titleStyle: testCase.style,
                  );
                  return Row(
                    children: [
                      SizedBox(
                        key: const ValueKey('cover'),
                        width: size.width,
                        height: size.height,
                      ),
                      Text(
                        'One\nTwo\nThree\nFour',
                        key: const ValueKey('four-line-title'),
                        style: testCase.style,
                        maxLines: collectionCardTitleMaxLines,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      final coverSize = tester.getSize(find.byKey(const ValueKey('cover')));
      final titleSize = tester.getSize(
        find.byKey(const ValueKey('four-line-title')),
      );
      expect(coverSize.height, closeTo(titleSize.height, 0.1));
      expect(
        coverSize.width / coverSize.height,
        closeTo(collectionCoverAspectRatio, 0.001),
      );
      firstHeight ??= coverSize.height;
      if (testCase.scale > 1 || testCase.style.fontSize! > 14) {
        expect(coverSize.height, greaterThan(firstHeight));
        scaledHeight = coverSize.height;
      }
    }

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            textScaler: TextScaler.linear(1.5),
          ),
          child: Scaffold(
            body: Builder(
              builder: (context) {
                const style = TextStyle(fontSize: 18, height: 1.1);
                final size = collectionListCoverSizeForTitle(
                  context,
                  titleStyle: style,
                );
                return Row(
                  children: [
                    SizedBox(
                      key: const ValueKey('cover'),
                      width: size.width,
                      height: size.height,
                    ),
                    const Text(
                      'Short',
                      key: ValueKey('short-title'),
                      style: style,
                      maxLines: collectionCardTitleMaxLines,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('cover'))).height,
      closeTo(scaledHeight!, 0.1),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('short-title'))).height,
      lessThan(tester.getSize(find.byKey(const ValueKey('cover'))).height),
    );
    expect(comicListCoverWidth, 112);
    expect(tester.takeException(), isNull);
  });

  testWidgets('list cover follows inherited theme text and system scaling', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          textTheme: const TextTheme(
            bodyMedium: TextStyle(fontSize: 17, height: 1.25),
          ),
        ),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 800),
            textScaler: TextScaler.linear(2.5),
          ),
          child: Scaffold(
            body: Builder(
              builder: (context) {
                final size = collectionListCoverSizeForTitle(
                  context,
                  titleStyle: null,
                );
                return Row(
                  children: [
                    SizedBox(
                      key: const ValueKey('cover'),
                      width: size.width,
                      height: size.height,
                    ),
                    const Expanded(
                      child: Text(
                        'One\nTwo\nThree\nFour',
                        key: ValueKey('four-line-title'),
                        maxLines: collectionCardTitleMaxLines,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );

    final coverSize = tester.getSize(find.byKey(const ValueKey('cover')));
    final titleSize = tester.getSize(
      find.byKey(const ValueKey('four-line-title')),
    );
    expect(coverSize.height, closeTo(titleSize.height, 0.1));
    expect(coverSize.width / coverSize.height, closeTo(4 / 3, 0.001));
    expect(tester.takeException(), isNull);
  });
}
