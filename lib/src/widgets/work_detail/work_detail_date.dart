import 'package:flutter/material.dart';

class WorkDetailDate extends StatelessWidget {
  const WorkDetailDate({super.key, required this.label, required this.date});

  final String label;
  final String date;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600], fontSize: 12);
    return Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(label, style: style),
        Text(date.split('T').first, style: style),
      ],
    );
  }
}
