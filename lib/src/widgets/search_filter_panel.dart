import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Keeps selected search conditions visible while their controls are collapsed.
class SearchFilterPanel extends StatefulWidget {
  const SearchFilterPanel({
    super.key,
    required this.headerBuilder,
    required this.filters,
    this.selected,
  });

  final Widget Function(BuildContext context, Widget filterButton)
  headerBuilder;
  final Widget filters;
  final Widget? selected;

  @override
  SearchFilterPanelState createState() => SearchFilterPanelState();
}

class SearchFilterPanelState extends State<SearchFilterPanel> {
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  void collapse() {
    if (_expanded) setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    final scrollBehavior = ScrollConfiguration.of(context);
    final filterButton = Semantics(
      expanded: _expanded,
      child: IconButton(
        key: const ValueKey('search-filter-toggle'),
        tooltip: S.of(context).filter,
        onPressed: _toggle,
        icon: Icon(_expanded ? Icons.expand_less : Icons.tune),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.headerBuilder(context, filterButton),
        if (widget.selected != null)
          ScrollConfiguration(
            behavior: scrollBehavior.copyWith(
              dragDevices: {
                ...scrollBehavior.dragDevices,
                PointerDeviceKind.mouse,
              },
            ),
            child: widget.selected!,
          ),
        if (_expanded) widget.filters,
      ],
    );
  }
}
