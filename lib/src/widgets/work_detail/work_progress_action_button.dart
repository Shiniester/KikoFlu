import 'package:flutter/material.dart';

import '../review_progress_dialog.dart';

class WorkProgressActionButton extends StatelessWidget {
  const WorkProgressActionButton({
    super.key,
    this.progress,
    this.isLoading = false,
    this.onPressed,
  });

  final String? progress;
  final bool isLoading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return isLoading ? _buildLoading(context) : _buildButton(context);
  }

  Widget _buildLoading(BuildContext context) {
    return SizedBox(
      width: 40,
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }

  Widget _buildButton(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final activeColor =
        progress != null ? colorScheme.primary : colorScheme.onSurface;
    final icon = Icon(
      ReviewProgressDialog.getProgressIcon(progress),
      color: activeColor,
    );

    return IconButton(
      onPressed: onPressed,
      tooltip: ReviewProgressDialog.getProgressLabel(progress, context),
      visualDensity: const VisualDensity(horizontal: -2),
      icon: icon,
    );
  }
}
