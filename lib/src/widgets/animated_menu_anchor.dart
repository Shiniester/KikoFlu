import 'package:flutter/material.dart';

/// A native [MenuAnchor] with a small whole-panel entrance transition.
///
/// Menu placement, scrolling, focus, outside-tap handling, and dismissal stay
/// with Flutter's menu implementation. Only the panel's visual entrance is
/// animated here.
class AnimatedMenuAnchor extends StatefulWidget {
  const AnimatedMenuAnchor({
    super.key,
    required this.menuChildren,
    required this.builder,
    this.controller,
    this.menuStyle,
    this.panelPadding = const EdgeInsets.symmetric(vertical: 8),
    this.transformOrigin = Alignment.topCenter,
    this.crossAxisUnconstrained = true,
    this.onOpen,
    this.onClose,
  });

  final List<Widget> menuChildren;
  final MenuAnchorChildBuilder builder;
  final MenuController? controller;
  final MenuStyle? menuStyle;
  final EdgeInsetsGeometry panelPadding;
  final Alignment transformOrigin;
  final bool crossAxisUnconstrained;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;

  @override
  State<AnimatedMenuAnchor> createState() => _AnimatedMenuAnchorState();
}

class _AnimatedMenuAnchorState extends State<AnimatedMenuAnchor> {
  final _ownedController = MenuController();
  LocalHistoryEntry? _historyEntry;

  MenuController get _controller => widget.controller ?? _ownedController;

  void _handleOpen() {
    final route = ModalRoute.of(context);
    if (route != null) {
      late final LocalHistoryEntry entry;
      entry = LocalHistoryEntry(
        onRemove: () {
          if (identical(_historyEntry, entry)) _historyEntry = null;
          _controller.close();
        },
      );
      _historyEntry = entry;
      route.addLocalHistoryEntry(entry);
    }
    widget.onOpen?.call();
  }

  void _handleClose() {
    final entry = _historyEntry;
    _historyEntry = null;
    entry?.remove();
    widget.onClose?.call();
  }

  @override
  void dispose() {
    final entry = _historyEntry;
    _historyEntry = null;
    entry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final menuStyle = widget.menuStyle;
    return MenuAnchor(
      controller: _controller,
      animated: false,
      useRootOverlay: true,
      consumeOutsideTap: true,
      crossAxisUnconstrained: widget.crossAxisUnconstrained,
      clipBehavior: Clip.none,
      onOpen: _handleOpen,
      onClose: _handleClose,
      style: (menuStyle ?? const MenuStyle()).copyWith(
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        shadowColor: const WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(side: BorderSide.none),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      menuChildren: [
        _AnimatedMenuPanel(
          padding: widget.panelPadding,
          transformOrigin: widget.transformOrigin,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: widget.menuChildren,
          ),
        ),
      ],
      builder: widget.builder,
    );
  }
}

class _AnimatedMenuPanel extends StatefulWidget {
  const _AnimatedMenuPanel({
    required this.padding,
    required this.transformOrigin,
    required this.child,
  });

  final EdgeInsetsGeometry padding;
  final Alignment transformOrigin;
  final Widget child;

  @override
  State<_AnimatedMenuPanel> createState() => _AnimatedMenuPanelState();
}

class _AnimatedMenuPanelState extends State<_AnimatedMenuPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 190),
  );
  late final Animation<double> _entrance = _controller.drive(
    CurveTween(curve: Curves.easeOut),
  );
  late final Animation<double> _scale = Tween<double>(
    begin: .96,
    end: 1,
  ).animate(_entrance);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final menuStyle = MenuTheme.of(context).style;
    final colorScheme = Theme.of(context).colorScheme;
    Color resolveColor(WidgetStateProperty<Color?>? property, Color fallback) =>
        property?.resolve(const {}) ?? fallback;
    final elevation = menuStyle?.elevation?.resolve(const {}) ?? 3.0;
    final shape =
        menuStyle?.shape?.resolve(const {}) ??
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
        );

    return FadeTransition(
      opacity: _entrance,
      alwaysIncludeSemantics: true,
      child: ScaleTransition(
        scale: _scale,
        alignment: widget.transformOrigin,
        child: Material(
          color: resolveColor(
            menuStyle?.backgroundColor,
            colorScheme.surfaceContainer,
          ),
          elevation: elevation,
          shadowColor: resolveColor(menuStyle?.shadowColor, colorScheme.shadow),
          surfaceTintColor: resolveColor(
            menuStyle?.surfaceTintColor,
            Colors.transparent,
          ),
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: widget.padding, child: widget.child),
        ),
      ),
    );
  }
}
