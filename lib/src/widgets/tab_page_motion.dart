import 'package:flutter/material.dart';

const tabPageDuration = Duration(milliseconds: 300);

/// Drives the official tab indicator from the page's actual scroll position.
void syncTabWithPage(TabController tabs, PageController pages) {
  if (!pages.hasClients || !pages.position.hasContentDimensions) return;
  final page = pages.page!.clamp(0.0, (tabs.length - 1).toDouble());
  tabs.index = page.round();
  tabs.offset = page - tabs.index;
}

Future<void> moveToTabPage(
  PageController pages,
  int index, {
  required bool reduceMotion,
}) {
  if (reduceMotion) {
    pages.jumpToPage(index);
    return Future.value();
  }
  return pages.animateToPage(
    index,
    duration: tabPageDuration,
    curve: Curves.ease,
  );
}

/// Keeps visited pages alive without loading pages crossed by a distant click.
class LazyTabPage extends StatefulWidget {
  const LazyTabPage({
    super.key,
    required this.index,
    required this.target,
    required this.pages,
    required this.child,
  });

  final int index;
  final ValueNotifier<int?> target;
  final PageController pages;
  final Widget child;

  @override
  State<LazyTabPage> createState() => _LazyTabPageState();
}

class _LazyTabPageState extends State<LazyTabPage>
    with AutomaticKeepAliveClientMixin {
  bool _visited = false;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AnimatedBuilder(
      animation: Listenable.merge([widget.pages, widget.target]),
      builder: (context, child) {
        final page =
            widget.pages.hasClients &&
                widget.pages.position.hasContentDimensions
            ? widget.pages.page!
            : widget.pages.initialPage.toDouble();
        _visited |=
            widget.target.value == widget.index ||
            (widget.target.value == null && (page - widget.index).abs() < 1);
        return _visited ? child! : const SizedBox.shrink();
      },
      child: widget.child,
    );
  }
}
