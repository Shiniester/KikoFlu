import 'package:flutter/material.dart';

typedef WorkDetailCoverBuilder =
    Widget Function(BuildContext context, bool isLandscape);

class WorkDetailResponsiveLayout extends StatelessWidget {
  const WorkDetailResponsiveLayout({
    super.key,
    required this.coverBuilder,
    required this.infoSliver,
    this.onRefresh,
  });

  final WorkDetailCoverBuilder coverBuilder;
  final Widget infoSliver;
  final RefreshCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final cover = coverBuilder(context, isLandscape);

    if (isLandscape) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 2, child: Center(child: cover)),
          Expanded(flex: 3, child: _buildScrollable(context, [infoSliver])),
        ],
      );
    }

    return _buildScrollable(context, [
      SliverToBoxAdapter(child: cover),
      infoSliver,
    ]);
  }

  Widget _buildScrollable(BuildContext context, List<Widget> slivers) {
    final scrollable = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: slivers,
    );

    if (onRefresh == null) return scrollable;

    return RefreshIndicator(onRefresh: onRefresh!, child: scrollable);
  }
}
