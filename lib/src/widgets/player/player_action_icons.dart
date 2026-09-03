import 'package:flutter/material.dart';

/// Shared player action geometry keeps dense queue and details actions aligned.
const IconData playerPlayNextIcon = Icons.skip_next_rounded;

class PlayerCompactAction extends StatelessWidget {
  const PlayerCompactAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: SizedBox.square(
          dimension: 32,
          child: Material(
            color: Colors.transparent,
            child: InkResponse(
              onTap: onPressed,
              radius: 16,
              containedInkWell: true,
              child: Center(child: Icon(icon, size: 18, color: color)),
            ),
          ),
        ),
      ),
    );
  }
}
