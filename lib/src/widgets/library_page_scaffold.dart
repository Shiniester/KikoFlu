import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../utils/system_ui_style.dart';

class LibraryPageScaffold extends StatefulWidget {
  const LibraryPageScaffold({
    super.key,
    required this.title,
    required this.searchHint,
    required this.onSearch,
    required this.body,
    required this.drawerChildren,
    this.searchScopeKey,
    this.searchQuery,
    this.onSearchCleared,
    this.floatingActionButton,
  });

  final String title;
  final String searchHint;
  final ValueChanged<String> onSearch;
  final Widget body;
  final List<Widget> drawerChildren;
  final Object? searchScopeKey;
  final String? searchQuery;
  final VoidCallback? onSearchCleared;
  final Widget? floatingActionButton;

  @override
  State<LibraryPageScaffold> createState() => _LibraryPageScaffoldState();
}

class _LibraryPageScaffoldState extends State<LibraryPageScaffold> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.text = widget.searchQuery ?? '';
  }

  @override
  void didUpdateWidget(covariant LibraryPageScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchHint != widget.searchHint ||
        oldWidget.searchScopeKey != widget.searchScopeKey) {
      _search.clear();
    } else if (oldWidget.searchQuery != widget.searchQuery &&
        widget.searchQuery != null) {
      _search.value = TextEditingValue(
        text: widget.searchQuery!,
        selection: TextSelection.collapsed(offset: widget.searchQuery!.length),
      );
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _submit(String value) {
    final query = value.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    widget.onSearch(query);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    return AnnotatedRegion(
      value: transparentSystemBarsForBrightness(theme.brightness),
      child: Scaffold(
        drawer: Drawer(
          key: const ValueKey('library-drawer'),
          width: math.min(320, width - 24),
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
              children: widget.drawerChildren,
            ),
          ),
        ),
        floatingActionButton: widget.floatingActionButton,
        body: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                key: const ValueKey('library-page-header'),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(
                  children: [
                    Builder(
                      builder: (context) => IconButton.filledTonal(
                        key: const ValueKey('library-menu-button'),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).openAppDrawerTooltip,
                        icon: const Icon(Icons.menu),
                        onPressed: () => Scaffold.of(context).openDrawer(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.min(110, width * .25),
                      ),
                      child: Tooltip(
                        message: widget.title,
                        child: Text(
                          widget.title,
                          key: const ValueKey('library-page-title'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('library-page-search'),
                        controller: _search,
                        textInputAction: TextInputAction.search,
                        onSubmitted: _submit,
                        onChanged: (value) {
                          setState(() {});
                          if (value.isEmpty) widget.onSearchCleared?.call();
                        },
                        decoration: InputDecoration(
                          hintText: widget.searchHint,
                          isDense: true,
                          filled: true,
                          fillColor: theme.colorScheme.surfaceContainerHighest,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide.none,
                          ),
                          prefixIcon: IconButton(
                            tooltip: S.of(context).search,
                            onPressed: () => _submit(_search.text),
                            icon: const Icon(Icons.search, size: 20),
                          ),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: S.of(context).clear,
                                  onPressed: () {
                                    setState(_search.clear);
                                    widget.onSearchCleared?.call();
                                  },
                                  icon: const Icon(Icons.close, size: 20),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: widget.body,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LibraryDrawerSection extends StatelessWidget {
  const LibraryDrawerSection({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(title, style: Theme.of(context).textTheme.labelMedium),
        ),
        ...children,
      ],
    ),
  );
}

class LibraryDrawerTile extends StatelessWidget {
  const LibraryDrawerTile({
    super.key,
    required this.icon,
    required this.title,
    this.selected = false,
    this.trailing,
    this.closeOnTap = true,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final bool selected;
  final Widget? trailing;
  final bool closeOnTap;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, size: 20),
    title: Text(title),
    selected: selected,
    selectedColor: Theme.of(context).colorScheme.primary,
    selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    trailing: trailing ?? (selected ? const Icon(Icons.check, size: 18) : null),
    onTap: onTap == null
        ? null
        : () {
            if (closeOnTap) Navigator.of(context).pop();
            onTap!();
          },
  );
}
