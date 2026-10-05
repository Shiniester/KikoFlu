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

/// Prepares the clicked page shell in the first frame, then restores lazy caching.
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

/// Defers content's first presentation until its owning pagers settle.
class DeferredTabContent extends StatefulWidget {
  const DeferredTabContent({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  State<DeferredTabContent> createState() => _DeferredTabContentState();
}

class _DeferredTabContentState extends State<DeferredTabContent> {
  _TabPageScope? _tab;
  Listenable? _motion;
  ValueNotifier<bool>? _scrolling;
  bool _presented = false;
  bool _releaseScheduled = false;

  bool get _canPresent =>
      _scrolling?.value != true && (_tab?.canPresent ?? true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_presented) return;
    _motion?.removeListener(_onMotionChanged);
    _tab = context.dependOnInheritedWidgetOfExactType<_TabPageScope>();
    _scrolling = Scrollable.maybeOf(
      context,
      axis: Axis.horizontal,
    )?.position.isScrollingNotifier;
    if (_canPresent) {
      _presented = true;
      _motion = null;
    } else {
      _motion = Listenable.merge([_scrolling, ...?_tab?.motion]);
      _motion!.addListener(_onMotionChanged);
    }
  }

  void _onMotionChanged() {
    if (!_canPresent || _releaseScheduled) return;
    _releaseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _releaseScheduled = false;
      if (!mounted || !_canPresent || _presented) return;
      _motion?.removeListener(_onMotionChanged);
      _motion = null;
      setState(() => _presented = true);
    });
  }

  @override
  void dispose() {
    _motion?.removeListener(_onMotionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _presented
      ? widget.builder(context)
      : const TickerMode(
          enabled: false,
          child: Center(child: CircularProgressIndicator()),
        );
}

class _TabPageScope extends InheritedWidget {
  const _TabPageScope({
    required this.index,
    required this.pages,
    required this.parent,
    required super.child,
  });

  final int index;
  final PageController pages;
  final _TabPageScope? parent;

  bool get canPresent =>
      isCurrent &&
      (!pages.hasClients || !pages.position.isScrollingNotifier.value) &&
      (parent?.canPresent ?? true);

  Iterable<Listenable> get motion sync* {
    yield pages;
    if (pages.hasClients) yield pages.position.isScrollingNotifier;
    if (parent != null) yield* parent!.motion;
  }

  bool get isCurrent {
    final page = pages.hasClients && pages.position.hasContentDimensions
        ? pages.page!
        : pages.initialPage.toDouble();
    return page.round() == index;
  }

  @override
  bool updateShouldNotify(_TabPageScope oldWidget) =>
      index != oldWidget.index ||
      pages != oldWidget.pages ||
      parent != oldWidget.parent;
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
      child: _TabPageScope(
        index: widget.index,
        pages: widget.pages,
        parent: context.dependOnInheritedWidgetOfExactType<_TabPageScope>(),
        child: widget.child,
      ),
    );
  }
}
