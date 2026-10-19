import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/system_ui_style.dart';
import 'settings_section.dart';

class LibraryPageScaffold extends StatelessWidget {
  const LibraryPageScaffold({
    super.key,
    required this.title,
    required this.searchHint,
    required this.onSearch,
    required this.body,
    required this.drawerChildren,
    this.drawerFooter,
    this.floatingActionButton,
  });

  final String title;
  final String searchHint;
  final VoidCallback onSearch;
  final Widget body;
  final List<Widget> drawerChildren;
  final Widget? drawerFooter;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    return AnnotatedRegion(
      value: transparentSystemBarsForBrightness(theme.brightness),
      child: Scaffold(
        drawer: Drawer(
          key: const ValueKey('library-drawer'),
          width: math.min(256, width - 48),
          child: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    children: drawerChildren,
                  ),
                ),
                if (drawerFooter != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                    child: drawerFooter!,
                  ),
              ],
            ),
          ),
        ),
        floatingActionButton: floatingActionButton,
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
                      builder: (context) => Tooltip(
                        message: MaterialLocalizations.of(
                          context,
                        ).openAppDrawerTooltip,
                        child: FilledButton.icon(
                          key: const ValueKey('library-menu-button'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 48),
                            padding: const EdgeInsets.all(12),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: theme.textTheme.titleSmall,
                            foregroundColor: theme.colorScheme.onSurface,
                            backgroundColor:
                                theme.colorScheme.surfaceContainerHighest,
                            side: BorderSide.none,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                            ),
                          ),
                          icon: const Icon(Icons.menu, size: 20),
                          label: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: math.min(110, width * .25),
                            ),
                            child: Text(
                              title,
                              key: const ValueKey('library-page-title'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          onPressed: () => Scaffold.of(context).openDrawer(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Semantics(
                        button: true,
                        child: Material(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(28),
                          child: InkWell(
                            key: const ValueKey('library-page-search'),
                            onTap: onSearch,
                            borderRadius: BorderRadius.circular(28),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 14,
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.search, size: 20),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      searchHint,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
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
                child: body,
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
    padding: const EdgeInsets.only(bottom: 8),
    child: SettingsSectionCard(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(fontSize: 14, height: 16 / 14),
            ),
          ),
          ...children,
        ],
      ),
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
    dense: true,
    minTileHeight: 48,
    minLeadingWidth: 20,
    horizontalTitleGap: 12,
    minVerticalPadding: 4,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
    leading: Icon(icon, size: 20),
    title: Text(title, style: const TextStyle(fontSize: 16)),
    leadingAndTrailingTextStyle: Theme.of(context).textTheme.bodyMedium,
    selected: selected,
    selectedColor: Theme.of(context).colorScheme.primary,
    selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    trailing: trailing,
    onTap: onTap == null
        ? null
        : () {
            if (closeOnTap) Navigator.of(context).pop();
            onTap!();
          },
  );
}
