import 'package:flutter/material.dart';

/// A Material dropdown field with the app's shared form-field defaults.
class MaterialDropdownButtonFormField<T> extends StatelessWidget {
  const MaterialDropdownButtonFormField({
    super.key,
    required this.initialValue,
    required this.items,
    required this.onChanged,
    required this.decoration,
    this.style,
    this.menuMaxHeight = 300,
  });

  final T? initialValue;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration decoration;
  final TextStyle? style;
  final double menuMaxHeight;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      initialValue: initialValue,
      decoration: decoration,
      style: style,
      menuMaxHeight: menuMaxHeight,
      items: items,
      onChanged: onChanged,
    );
  }
}

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
