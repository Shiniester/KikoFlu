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

/// Lays out the clicked page in the first frame, then restores lazy caching.
class TabPageWarmup extends StatefulWidget {
  const TabPageWarmup({
    super.key,
    required this.pages,
    required this.target,
    required this.builder,
  });

  final PageController pages;
  final ValueNotifier<int?> target;
  final Widget Function(double cacheExtent) builder;

  @override
  State<TabPageWarmup> createState() => _TabPageWarmupState();
}

class _TabPageWarmupState extends State<TabPageWarmup> {
  double _cacheExtent = 0;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    widget.target.addListener(_prepareTarget);
    _prepareTarget();
  }

  @override
  void didUpdateWidget(TabPageWarmup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target != widget.target) {
      oldWidget.target.removeListener(_prepareTarget);
      widget.target.addListener(_prepareTarget);
      _prepareTarget();
    }
  }

  void _prepareTarget() {
    final request = ++_request;
    final target = widget.target.value;
    final page =
        widget.pages.hasClients && widget.pages.position.hasContentDimensions
        ? widget.pages.page!
        : widget.pages.initialPage.toDouble();
    final extent = target == null ? 0.0 : (target - page).abs().ceilToDouble();
    if (_cacheExtent != extent) setState(() => _cacheExtent = extent);
    if (extent == 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _request) return;
      setState(() => _cacheExtent = 0);
    });
  }

  @override
  void dispose() {
    widget.target.removeListener(_prepareTarget);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_cacheExtent);
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
