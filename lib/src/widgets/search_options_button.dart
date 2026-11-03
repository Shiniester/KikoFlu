import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'animated_menu_anchor.dart';

/// Keeps search options in a bounded popup without resizing the results.
class SearchOptionsButton extends StatelessWidget {
  const SearchOptionsButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.child,
  });

  final IconData icon;
  final String tooltip;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = math.min(360.0, media.size.width - 32);
    final height = math.max(
      48.0,
      math.min(
        480.0,
        media.size.height -
            media.padding.vertical -
            media.viewInsets.vertical -
            kToolbarHeight -
            24,
      ),
    );
    return AnimatedMenuAnchor(
      menuStyle: const MenuStyle(
        alignment: AlignmentDirectional.bottomEnd,
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      menuChildren: [
        SizedBox(
          width: width,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: height),
            child: Focus(
              autofocus: true,
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  Navigator.of(context).maybePop();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: SingleChildScrollView(
                primary: false,
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      tooltip,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    child,
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
      builder: (context, controller, _) => Semantics(
        expanded: controller.isOpen,
        child: IconButton(
          tooltip: tooltip,
          icon: Icon(icon),
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              FocusManager.instance.primaryFocus?.unfocus();
              controller.open();
            }
          },
        ),
      ),
    );
  }
}
