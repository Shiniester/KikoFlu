import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'floating_feed_toolbar.dart';

bool updateLibraryToolbarVisibility(
  ScrollNotification notification,
  ValueNotifier<bool> visible,
) {
  if (notification.metrics.axis != Axis.vertical) return false;
  if (notification.metrics.pixels <= notification.metrics.minScrollExtent) {
    visible.value = true;
    return false;
  }
  final pastHeader =
      notification.metrics.pixels - notification.metrics.minScrollExtent >=
      kTextTabBarHeight;
  if (notification is ScrollUpdateNotification &&
      notification.scrollDelta != null) {
    if (notification.scrollDelta! < 0) visible.value = true;
    if (notification.scrollDelta! > 0 && pastHeader) visible.value = false;
  } else if (notification is UserScrollNotification) {
    if (notification.direction == ScrollDirection.forward) visible.value = true;
    if (notification.direction == ScrollDirection.reverse && pastHeader) {
      visible.value = false;
    }
  }
  return false;
}

class LibraryTabStrip extends StatelessWidget {
  const LibraryTabStrip({
    super.key,
    required this.controller,
    required this.visible,
    required this.tabs,
    this.motionKey,
  });
  final TabController controller;
  final ValueListenable<bool> visible;
  final List<Widget> tabs;
  final Key? motionKey;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: visible,
    builder: (context, show, child) => IgnorePointer(
      ignoring: !show,
      child: AnimatedSlide(
        key: motionKey,
        offset: show || MediaQuery.disableAnimationsOf(context)
            ? Offset.zero
            : const Offset(0, -2),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: show ? 1 : 0,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 140),
          child: ExcludeFocus(
            excluding: !show,
            child: ExcludeSemantics(excluding: !show, child: child),
          ),
        ),
      ),
    ),
    child: FloatingToolbarSurface(
      child: SizedBox(
        height: 40,
        child: TabBar(
          controller: controller,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          dividerColor: Colors.transparent,
          indicatorSize: TabBarIndicatorSize.tab,
          indicator: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          labelColor: Theme.of(context).colorScheme.primary,
          unselectedLabelColor: Theme.of(context).colorScheme.onSurfaceVariant,
          splashBorderRadius: BorderRadius.circular(20),
          tabs: tabs,
        ),
      ),
    ),
  );
}
