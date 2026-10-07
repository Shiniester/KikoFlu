import 'package:flutter/material.dart';

/// A native animated [MenuAnchor] with scoped back-button dismissal.
class AnimatedMenuAnchor extends StatefulWidget {
  const AnimatedMenuAnchor({
    super.key,
    required this.menuChildren,
    required this.builder,
    this.controller,
    this.menuStyle,
    this.crossAxisUnconstrained = true,
    this.onOpen,
    this.onClose,
  });

  final List<Widget> menuChildren;
  final MenuAnchorChildBuilder builder;
  final MenuController? controller;
  final MenuStyle? menuStyle;
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
    return MenuAnchor(
      controller: _controller,
      animated: !MediaQuery.disableAnimationsOf(context),
      useRootOverlay: true,
      consumeOutsideTap: true,
      crossAxisUnconstrained: widget.crossAxisUnconstrained,
      onOpen: _handleOpen,
      onClose: _handleClose,
      style: widget.menuStyle,
      menuChildren: widget.menuChildren,
      builder: widget.builder,
    );
  }
}
