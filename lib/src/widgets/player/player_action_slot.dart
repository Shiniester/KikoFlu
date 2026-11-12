import 'package:flutter/material.dart';

class PlayerActionSlot extends StatelessWidget {
  static const double buttonHeight = 48;
  static const double labelFontSize = 9;

  final bool isLandscape;
  final Widget child;
  final String? label;

  const PlayerActionSlot({
    super.key,
    required this.isLandscape,
    required this.child,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: isLandscape ? buttonHeight : 62),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: buttonHeight,
            child: Center(widthFactor: 1, child: child),
          ),
          if (label != null)
            Text(
              label!,
              style: TextStyle(
                fontSize: labelFontSize,
                height: 1,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}
