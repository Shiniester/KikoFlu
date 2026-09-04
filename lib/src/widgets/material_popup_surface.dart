import 'package:flutter/material.dart';

/// Gives overlay content the same classic Material popup surface everywhere.
class MaterialPopupSurface extends StatelessWidget {
  const MaterialPopupSurface({super.key, required this.child, this.maxHeight});

  final Widget child;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final content = maxHeight == null
        ? child
        : ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight!),
            child: child,
          );
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(4),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }
}
