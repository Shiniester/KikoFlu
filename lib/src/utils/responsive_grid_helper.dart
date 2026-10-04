import 'package:flutter/material.dart';

/// 响应式布局工具类
/// 根据屏幕尺寸和方向自动计算最佳列数
class ResponsiveGridHelper {
  static int _fitColumnsToWidth({
    required double width,
    required int preferredColumns,
    required int minimumColumns,
    required double horizontalPadding,
    required double crossAxisSpacing,
    required double minimumCardWidth,
  }) {
    var columns = preferredColumns;
    final safeWidth = width.isFinite ? width : 0.0;

    while (columns > minimumColumns) {
      final cardWidth =
          (safeWidth -
              horizontalPadding * 2 -
              crossAxisSpacing * (columns - 1)) /
          columns;
      if (cardWidth >= minimumCardWidth) break;
      columns--;
    }

    return columns.clamp(minimumColumns, preferredColumns).toInt();
  }

  static (double width, double height) _availableSize(
    BuildContext context, {
    double? availableWidth,
    double? availableHeight,
  }) {
    final mediaSize = MediaQuery.sizeOf(context);
    final width = availableWidth ?? mediaSize.width;
    final height = availableHeight ?? mediaSize.height;
    return (width, height);
  }

  /// 根据屏幕尺寸计算大网格的列数
  ///
  /// 逻辑：
  /// - 竖屏：优先2列，卡片过窄时降为1列
  /// - 横屏：
  ///   - 屏幕宽度 < 1200px 或宽高比 < 1.3：优先3列
  ///   - 屏幕宽度 >= 1200px 且宽高比 >= 1.3：优先4列
  /// - 所有模式都按实际可用宽度保留最小卡片宽度。
  static int getBigGridCrossAxisCount(
    BuildContext context, {
    double? availableWidth,
    double? availableHeight,
    double horizontalPadding = 8,
    double crossAxisSpacing = 8,
  }) {
    final (width, height) = _availableSize(
      context,
      availableWidth: availableWidth,
      availableHeight: availableHeight,
    );
    final isLandscape = width > height;
    final aspectRatio = height > 0 ? width / height : double.infinity;
    final preferredColumns = !isLandscape
        ? 2
        : (width >= 1200 && aspectRatio >= 1.3 ? 4 : 3);

    return _fitColumnsToWidth(
      width: width,
      preferredColumns: preferredColumns,
      minimumColumns: 1,
      horizontalPadding: horizontalPadding,
      crossAxisSpacing: crossAxisSpacing,
      minimumCardWidth: isLandscape ? 180 : 160,
    );
  }

  /// 根据屏幕尺寸计算小网格的列数
  ///
  /// 逻辑：
  /// - 竖屏：优先3列
  /// - 横屏：优先5列
  /// - 极窄窗口至少保留2列，避免网格退化为列表。
  static int getSmallGridCrossAxisCount(
    BuildContext context, {
    double? availableWidth,
    double? availableHeight,
    double horizontalPadding = 8,
    double crossAxisSpacing = 8,
  }) {
    final (width, height) = _availableSize(
      context,
      availableWidth: availableWidth,
      availableHeight: availableHeight,
    );
    final preferredColumns = width > height ? 5 : 3;

    return _fitColumnsToWidth(
      width: width,
      preferredColumns: preferredColumns,
      minimumColumns: 2,
      horizontalPadding: horizontalPadding,
      crossAxisSpacing: crossAxisSpacing,
      minimumCardWidth: 96,
    );
  }
}
