import 'package:flutter/material.dart';

import '../providers/works_provider.dart';
import 'responsive_grid_helper.dart';

const double collectionCoverAspectRatio = 4 / 3;
const double comicListCoverWidth = 112;
const int collectionCardTitleMaxLines = 4;
const double collectionGridInfoPadding = 8;
const double collectionCardInfoSpacing = 4;
const double collectionListCardVerticalMargin = 4;

Size collectionListCoverSizeForTitle(
  BuildContext context, {
  required TextStyle? titleStyle,
}) {
  final defaultTextStyle = DefaultTextStyle.of(context);
  var effectiveStyle = titleStyle == null || titleStyle.inherit
      ? defaultTextStyle.style.merge(titleStyle)
      : titleStyle;
  if (MediaQuery.boldTextOf(context)) {
    effectiveStyle = effectiveStyle.merge(
      const TextStyle(fontWeight: FontWeight.bold),
    );
  }
  effectiveStyle = effectiveStyle.merge(
    TextStyle(
      height: MediaQuery.maybeLineHeightScaleFactorOverrideOf(context),
      letterSpacing: MediaQuery.maybeLetterSpacingOverrideOf(context),
      wordSpacing: MediaQuery.maybeWordSpacingOverrideOf(context),
    ),
  );

  final painter = TextPainter(
    text: TextSpan(text: 'Ag\nAg\nAg\nAg', style: effectiveStyle),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    locale: Localizations.maybeLocaleOf(context),
    textHeightBehavior:
        defaultTextStyle.textHeightBehavior ??
        DefaultTextHeightBehavior.maybeOf(context),
    textWidthBasis: defaultTextStyle.textWidthBasis,
    maxLines: collectionCardTitleMaxLines,
  )..layout();
  final height = painter.height;
  painter.dispose();
  return Size(height * collectionCoverAspectRatio, height);
}

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
    LayoutType.bigGrid => ResponsiveGridHelper.getBigGridCrossAxisCount(
      context,
      availableWidth: width,
      availableHeight: height,
      horizontalPadding: horizontalPadding,
      crossAxisSpacing: spacing,
    ),
    LayoutType.smallGrid => ResponsiveGridHelper.getSmallGridCrossAxisCount(
      context,
      availableWidth: width,
      availableHeight: height,
      horizontalPadding: horizontalPadding,
      crossAxisSpacing: spacing,
    ),
    LayoutType.list => 1,
  };

  return CollectionGridMetrics(
    crossAxisCount: crossAxisCount,
    spacing: spacing,
    padding: resolvedPadding,
  );
}
