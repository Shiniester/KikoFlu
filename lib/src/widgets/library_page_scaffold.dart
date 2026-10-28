import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior, kTouchSlop;
import 'package:flutter/material.dart';

import '../utils/system_ui_style.dart';
import 'settings_section.dart';

class LibraryPageScaffold extends StatefulWidget {
  const LibraryPageScaffold({
    super.key,
    required this.title,
    required this.searchHint,
    required this.onSearch,
    required this.body,
    required this.drawerChildren,
    this.deferDrawerActions = false,
    this.drawerFooter,
    this.floatingActionButton,
  });

  final String title;
  final String searchHint;
  final VoidCallback onSearch;
  final Widget body;
  final List<Widget> drawerChildren;
  final bool deferDrawerActions;
  final Widget? drawerFooter;
  final Widget? floatingActionButton;

  @override
  State<LibraryPageScaffold> createState() => _LibraryPageScaffoldState();
}

class _LibraryPageScaffoldState extends State<LibraryPageScaffold> {
  final GlobalKey<_LibraryDrawerLifecycleState> _drawerLifecycleKey =
      GlobalKey<_LibraryDrawerLifecycleState>();
  VoidCallback? _pendingDrawerAction;
  double _drawerDragDistance = 0;

  @override
  void didUpdateWidget(LibraryPageScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.deferDrawerActions) _pendingDrawerAction = null;
  }

  void _onDrawerChanged(bool isOpened) {
    if (isOpened) _pendingDrawerAction = null;
  }

  void _deferDrawerAction(BuildContext context, VoidCallback action) {
    _pendingDrawerAction = action;
    Scaffold.of(context).closeDrawer();
  }

  void _onDrawerChildDisposed() {
    // Material unmounts Drawer.child when the close animation is dismissed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _drawerLifecycleKey.currentState != null) return;
      final action = _pendingDrawerAction;
      _pendingDrawerAction = null;
      if (action == null ||
          !widget.deferDrawerActions ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      action();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    return AnnotatedRegion(
      value: transparentSystemBarsForBrightness(theme.brightness),
      child: Scaffold(
        onDrawerChanged: _onDrawerChanged,
        drawer: Drawer(
          key: const ValueKey('library-drawer'),
          backgroundColor: theme.scaffoldBackgroundColor,
          width: math.min(224, width - 48),
          child: widget.deferDrawerActions
              ? _LibraryDrawerLifecycle(
                  key: _drawerLifecycleKey,
                  onDisposed: _onDrawerChildDisposed,
                  child: _drawerContent(),
                )
              : _drawerContent(),
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
                              widget.title,
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
                            onTap: widget.onSearch,
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
                                      widget.searchHint,
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
              child: Builder(
                builder: (context) => GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  dragStartBehavior: DragStartBehavior.down,
                  onHorizontalDragStart: (_) => _drawerDragDistance = 0,
                  onHorizontalDragUpdate: (details) =>
                      _drawerDragDistance += details.primaryDelta ?? 0,
                  onHorizontalDragEnd: (_) {
                    if (_drawerDragDistance > kTouchSlop) {
                      Scaffold.of(context).openDrawer();
                    }
                  },
                  child: MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: widget.body,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerContent() => SafeArea(
    child: ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      children: [
        ...widget.drawerChildren,
        if (widget.drawerFooter != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: widget.drawerFooter!,
          ),
      ],
    ),
  );
}

class _LibraryDrawerLifecycle extends StatefulWidget {
  const _LibraryDrawerLifecycle({
    super.key,
    required this.onDisposed,
    required this.child,
  });

  final VoidCallback onDisposed;
  final Widget child;

  @override
  State<_LibraryDrawerLifecycle> createState() =>
      _LibraryDrawerLifecycleState();
}

class _LibraryDrawerLifecycleState extends State<_LibraryDrawerLifecycle> {
  @override
  void dispose() {
    widget.onDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
            padding: const EdgeInsets.all(12),
            child: Text(
              title,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: 12,
                height: 16 / 12,
                fontWeight: FontWeight.normal,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SettingsDivider(indent: 12, endIndent: 12),
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
    this.subtitle,
    this.trailing,
    this.closeOnTap = true,
    this.onTap,
    this.children = const [],
  });

  final IconData icon;
  final String title;
  final bool selected;
  final Widget? subtitle;
  final Widget? trailing;
  final bool closeOnTap;
  final VoidCallback? onTap;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tile = ListTile(
      dense: true,
      minTileHeight: 48,
      minLeadingWidth: 20,
      horizontalTitleGap: 12,
      minVerticalPadding: 4,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(icon, size: 20),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: selected ? FontWeight.bold : null,
        ),
      ),
      subtitle: subtitle,
      leadingAndTrailingTextStyle: Theme.of(context).textTheme.bodyMedium,
      selected: selected,
      selectedColor: Theme.of(context).colorScheme.primary,
      selectedTileColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      trailing: trailing,
      onTap: onTap == null
          ? null
          : () {
              final scaffold = context
                  .findAncestorStateOfType<_LibraryPageScaffoldState>();
              if (closeOnTap &&
                  scaffold != null &&
                  scaffold.widget.deferDrawerActions) {
                scaffold._deferDrawerAction(context, onTap!);
              } else {
                if (closeOnTap) Navigator.of(context).pop();
                onTap!();
              }
            },
    );
    if (children.isEmpty) return tile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tile,
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }
}
