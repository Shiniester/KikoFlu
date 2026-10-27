import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/work_card_display_provider.dart';
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
                      cardSize: WorkCardSize.normal,
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
}
