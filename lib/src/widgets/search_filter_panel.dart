import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Keeps selected search conditions visible while their controls are collapsed.
class SearchFilterPanel extends StatefulWidget {
  const SearchFilterPanel({super.key, required this.filters, this.selected});

  final Widget filters;
  final Widget? selected;

  @override
  State<SearchFilterPanel> createState() => _SearchFilterPanelState();
}

class _SearchFilterPanelState extends State<SearchFilterPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.selected != null) widget.selected!,
        Semantics(
          expanded: _expanded,
          child: TextButton.icon(
            onPressed: () => setState(() => _expanded = !_expanded),
            icon: Icon(_expanded ? Icons.expand_less : Icons.tune),
            label: Text(S.of(context).filter),
          ),
        ),
        if (_expanded) widget.filters,
      ],
    );
  }
}
