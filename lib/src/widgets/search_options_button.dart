import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'responsive_dialog.dart';

/// Opens search options in a centered dialog without resizing the results.
class SearchOptionsButton extends StatelessWidget {
  const SearchOptionsButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.contentBuilder,
  });

  final IconData icon;
  final String tooltip;
  final Widget Function(BuildContext context, StateSetter setDialogState)
  contentBuilder;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    icon: Icon(icon),
    visualDensity: const VisualDensity(horizontal: -2),
    onPressed: () {
      FocusManager.instance.primaryFocus?.unfocus();
      showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => Focus(
            autofocus: true,
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                Navigator.of(context).maybePop();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: ResponsiveDialog(
              maxWidth: 420,
              titlePadding: const EdgeInsets.fromLTRB(20, 14, 8, 0),
              contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              title: Row(
                children: [
                  Icon(
                    icon,
                    size: 22,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tooltip,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                  ),
                ],
              ),
              content: contentBuilder(context, setDialogState),
            ),
          ),
        ),
      );
    },
  );
}
