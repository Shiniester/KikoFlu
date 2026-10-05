import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

class ComicReaderMenuButton<T> extends StatefulWidget {
  const ComicReaderMenuButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.itemBuilder,
    required this.onSelected,
  });

  final String tooltip;
  final Widget icon;
  final PopupMenuItemBuilder<T> itemBuilder;
  final ValueChanged<T> onSelected;

  @override
  State<ComicReaderMenuButton<T>> createState() =>
      _ComicReaderMenuButtonState<T>();
}

class _ComicReaderMenuButtonState<T> extends State<ComicReaderMenuButton<T>> {
  Future<void> _showMenu() async {
    final anchorContext = context;
    final selected = await showGeneralDialog<T>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 300),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          child,
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final overlay = Navigator.of(
          dialogContext,
          rootNavigator: true,
        ).overlay!;
        final overlayBox = overlay.context.findRenderObject()! as RenderBox;

        return LayoutBuilder(
          builder: (context, constraints) {
            if (!anchorContext.mounted) return const SizedBox.shrink();

            final anchorBox = anchorContext.findRenderObject()! as RenderBox;
            final anchorRect =
                anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox) &
                anchorBox.size;
            final mediaPadding = MediaQuery.paddingOf(context);
            final width = math.max(
              0.0,
              math.min(
                240.0,
                constraints.maxWidth -
                    mediaPadding.left -
                    mediaPadding.right -
                    16,
              ),
            );
            final minLeft = mediaPadding.left + 8;
            final maxLeft =
                constraints.maxWidth - mediaPadding.right - 8 - width;
            final left = (anchorRect.right - width)
                .clamp(minLeft, maxLeft)
                .toDouble();

            final top = math.min(constraints.maxHeight, mediaPadding.top + 8);
            final bottom = (anchorRect.top - 8)
                .clamp(top, constraints.maxHeight)
                .toDouble();
            final maxHeight = bottom - top;
            final theme = Theme.of(context);
            final popupTheme = PopupMenuTheme.of(context);

            return Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  bottom: constraints.maxHeight - bottom,
                  width: width,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: SizeTransition(
                      sizeFactor: animation.drive(
                        CurveTween(curve: Curves.ease),
                      ),
                      alignment: Alignment.bottomLeft,
                      child: Semantics(
                        role: SemanticsRole.menu,
                        scopesRoute: true,
                        namesRoute: true,
                        label: MaterialLocalizations.of(context).popupMenuLabel,
                        explicitChildNodes: true,
                        child: Material(
                          key: const ValueKey('comic-reader-menu-surface'),
                          color:
                              popupTheme.color ??
                              theme.colorScheme.surfaceContainer,
                          elevation: popupTheme.elevation ?? 8,
                          shape:
                              popupTheme.shape ??
                              RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4),
                              ),
                          clipBehavior: Clip.antiAlias,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: maxHeight),
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: widget.itemBuilder(dialogContext),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (selected != null && mounted) widget.onSelected(selected);
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: widget.tooltip,
    icon: widget.icon,
    onPressed: _showMenu,
  );
}
