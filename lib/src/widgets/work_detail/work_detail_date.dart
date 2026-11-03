import 'package:flutter/material.dart';

import 'work_detail_section_title.dart';

class WorkDetailDate extends StatelessWidget {
  const WorkDetailDate({super.key, required this.label, required this.date});

  final String label;
  final String date;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      WorkDetailSectionTitle(label),
      Text(
        date.split('T').first,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 14),
      ),
    ],
  );
}
