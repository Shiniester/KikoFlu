import 'package:flutter/material.dart';

import '../providers/work_card_display_provider.dart';
import '../providers/works_provider.dart';
import 'responsive_grid_helper.dart';

const double collectionCoverAspectRatio = 4 / 3;
const Size collectionListCoverSize = Size(112, 84);
const int collectionCardTitleMaxLines = 4;

double collectionCoverRadius(double width) => width / 15;

double collectionCoverInfoScale(double width) =>
    (width / 180).clamp(0.7, 1.0).toDouble();

EdgeInsets collectionCardPadding(
  BuildContext context, {
  EdgeInsetsGeometry? padding,
}) {
  final size = MediaQuery.sizeOf(context);
  final horizontal = size.width > size.height ? 24.0 : 8.0;
  return (padding ?? EdgeInsets.all(horizontal))
      .resolve(Directionality.of(context))
      .copyWith(left: horizontal, right: horizontal);
}

class CollectionGridMetrics {
  const CollectionGridMetrics({
    required this.crossAxisCount,
    required this.spacing,
    required this.padding,
  });

  final int crossAxisCount;
  final double spacing;
  final EdgeInsets padding;
}

CollectionGridMetrics resolveCollectionGridMetrics(
  BuildContext context, {
  required LayoutType layoutType,
  required WorkCardSize cardSize,
  EdgeInsetsGeometry? padding,
  double? availableWidth,
  double? availableHeight,
}) {
  final mediaSize = MediaQuery.sizeOf(context);
  final width = availableWidth ?? mediaSize.width;
  final height = availableHeight ?? mediaSize.height;
  final isLandscape = width > height;
  final spacing = isLandscape ? 24.0 : 8.0;
  final resolvedPadding = (padding ?? collectionCardPadding(context)).resolve(
    Directionality.of(context),
  );
  final horizontalPadding = resolvedPadding.horizontal / 2;
  final crossAxisCount = switch (layoutType) {
    LayoutType.bigGrid => cardSize.applyToCrossAxisCount(
      ResponsiveGridHelper.getBigGridCrossAxisCount(
        context,
        availableWidth: width,
        availableHeight: height,
        horizontalPadding: horizontalPadding,
        crossAxisSpacing: spacing,
      ),
    ),
    LayoutType.smallGrid => cardSize.applyToCrossAxisCount(
      ResponsiveGridHelper.getSmallGridCrossAxisCount(
        context,
        availableWidth: width,
        availableHeight: height,
        horizontalPadding: horizontalPadding,
        crossAxisSpacing: spacing,
      ),
      minCrossAxisCount: 2,
    ),
    LayoutType.list => 1,
  };

  return CollectionGridMetrics(
    crossAxisCount: crossAxisCount,
    spacing: spacing,
    padding: resolvedPadding,
  );
}
