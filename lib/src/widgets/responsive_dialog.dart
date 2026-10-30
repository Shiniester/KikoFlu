import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'app_navigation_scope.dart';

/// 响应式对话框封装
/// 横屏时限制最大宽度，避免过宽
class ResponsiveDialog extends StatelessWidget {
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? contentPadding;
  final EdgeInsetsGeometry? actionsPadding;
  final EdgeInsetsGeometry? titlePadding;
  final double? maxWidth;

  const ResponsiveDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.contentPadding,
    this.actionsPadding,
    this.titlePadding,
    this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final screenWidth = MediaQuery.of(context).size.width;

    // 横屏时限制对话框最大宽度
    // 使用 ConstrainedBox 而不是直接设置 AlertDialog 的宽度，避免布局问题
    final dialogMaxWidth =
        maxWidth ??
        (isLandscape
            ? screenWidth *
                  0.6 // 横屏时最多占60%宽度
            : screenWidth * 0.85); // 竖屏时最多占85%宽度

    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogMaxWidth,
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding:
                    titlePadding ??
                    const EdgeInsets.fromLTRB(24.0, 24.0, 24.0, 0.0),
                child: DefaultTextStyle(
                  style: Theme.of(context).textTheme.titleLarge!,
                  child: title!,
                ),
              ),
            if (content != null)
              Flexible(
                child: SingleChildScrollView(
                  padding:
                      contentPadding ??
                      const EdgeInsets.fromLTRB(24.0, 20.0, 24.0, 24.0),
                  child: DefaultTextStyle(
                    style: Theme.of(context).textTheme.bodyMedium!,
                    child: content!,
                  ),
                ),
              ),
            if (actions != null && actions!.isNotEmpty)
              Padding(
                padding:
                    actionsPadding ??
                    const EdgeInsets.only(left: 8.0, right: 8.0, bottom: 8.0),
                child: OverflowBar(
                  alignment: MainAxisAlignment.end,
                  spacing: 8.0,
                  children: actions!,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 响应式 AlertDialog 封装
/// 自动根据屏幕方向调整最大宽度
class ResponsiveAlertDialog extends StatelessWidget {
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? contentPadding;
  final EdgeInsetsGeometry? actionsPadding;
  final EdgeInsetsGeometry? titlePadding;
  final double? maxWidth;

  const ResponsiveAlertDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.contentPadding,
    this.actionsPadding,
    this.titlePadding,
    this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final screenWidth = MediaQuery.of(context).size.width;

    // 横屏时限制对话框最大宽度
    final dialogMaxWidth =
        maxWidth ??
        (isLandscape
            ? screenWidth *
                  0.6 // 横屏时最多占60%宽度
            : screenWidth * 0.85); // 竖屏时最多占85%宽度

    return AlertDialog(
      title: title,
      content: content != null
          ? ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: dialogMaxWidth,
                maxHeight: MediaQuery.of(context).size.height * 0.6,
              ),
              child: content,
            )
          : null,
      actions: actions,
      contentPadding: contentPadding,
      actionsPadding: actionsPadding,
      titlePadding: titlePadding,
    );
  }
}

/// 响应式 BottomSheet 封装
/// 横屏时使用右侧模态面板，竖屏时使用底部弹窗
class ResponsiveBottomSheet extends StatelessWidget {
  final Widget child;
  final double? maxWidth;
  final double? maxHeight;
  final ValueListenable<double>? _maxHeightListenable;
  final bool _isScrollControlled;
  final bool _enableDrag;
  final bool _disableAnimations;
  final AnimationController? _animationController;
  final Animation<double>? _slideAnimation;
  final VoidCallback? _onClosing;
  final BottomSheetDragStartHandler? _onDragStart;
  final BottomSheetDragEndHandler? _onDragEnd;
  final GlobalKey? _panelKey;
  final VoidCallback? _onPanelSizeChanged;

  const ResponsiveBottomSheet({
    super.key,
    required this.child,
    this.maxWidth,
    this.maxHeight,
  }) : _maxHeightListenable = null,
       _isScrollControlled = true,
       _enableDrag = false,
       _disableAnimations = false,
       _animationController = null,
       _slideAnimation = null,
       _onClosing = null,
       _onDragStart = null,
       _onDragEnd = null,
       _panelKey = null,
       _onPanelSizeChanged = null;

  const ResponsiveBottomSheet._modal({
    required this.child,
    this.maxWidth,
    this.maxHeight,
    required this._maxHeightListenable,
    required this._isScrollControlled,
    required this._enableDrag,
    required this._disableAnimations,
    required this._animationController,
    required this._slideAnimation,
    required this._onClosing,
    required this._onDragStart,
    required this._onDragEnd,
    required this._panelKey,
    required this._onPanelSizeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    final disableAnimations =
        _disableAnimations || MediaQuery.disableAnimationsOf(context);

    return ListenableBuilder(
      listenable: _maxHeightListenable ?? kAlwaysDismissedAnimation,
      builder: (context, _) => AnimatedPadding(
        padding: MediaQuery.viewInsetsOf(context),
        duration: disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final availableHeight = constraints.maxHeight;
            final requestedMaxHeight = _maxHeightListenable?.value ?? maxHeight;
            final sheetMaxHeight = math.min(
              requestedMaxHeight ??
                  (isLandscape
                      ? availableHeight
                      : availableHeight * (_isScrollControlled ? 0.9 : 9 / 16)),
              availableHeight,
            );
            final sheetMaxWidth = isLandscape
                ? math.min(
                    maxWidth ?? math.min(constraints.maxWidth * 0.6, 420),
                    constraints.maxWidth,
                  )
                : math.min(maxWidth ?? 640, constraints.maxWidth);
            final sheetTheme = Theme.of(context).bottomSheetTheme;
            ShapeBorder? shape;
            if (isLandscape) {
              shape =
                  sheetTheme.shape ??
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  );
              if (shape is RoundedRectangleBorder) {
                final radius = shape.borderRadius.resolve(
                  Directionality.of(context),
                );
                shape = shape.copyWith(
                  borderRadius: radius.copyWith(bottomLeft: radius.topLeft),
                );
              }
            }

            final panel = SizedBox(
              key: _panelKey,
              width: sheetMaxWidth,
              child: BottomSheet(
                key: const ValueKey('responsive-sheet-surface'),
                animationController: _animationController,
                onClosing: _onClosing ?? () {},
                onDragStart: _onDragStart,
                onDragEnd: _onDragEnd,
                enableDrag: !isLandscape && _enableDrag,
                shape: shape,
                clipBehavior: Clip.antiAlias,
                constraints: BoxConstraints(
                  minHeight: isLandscape && requestedMaxHeight == null
                      ? sheetMaxHeight
                      : 0,
                  maxWidth: sheetMaxWidth,
                  maxHeight: sheetMaxHeight,
                ),
                builder: (context) => SafeArea(top: isLandscape, child: child),
              ),
            );

            return Align(
              alignment: isLandscape
                  ? Alignment.centerRight
                  : Alignment.bottomCenter,
              child: NotificationListener<SizeChangedLayoutNotification>(
                onNotification: (_) {
                  _onPanelSizeChanged?.call();
                  return false;
                },
                child: SizeChangedLayoutNotifier(
                  child: _slideAnimation == null
                      ? panel
                      : SlideTransition(
                          position: _slideAnimation.drive(
                            Tween<Offset>(
                              begin: isLandscape
                                  ? const Offset(1, 0)
                                  : const Offset(0, 1),
                              end: Offset.zero,
                            ),
                          ),
                          child: panel,
                        ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class BottomSheetHeader extends StatelessWidget {
  const BottomSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing = const [],
    this.showCloseButton = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> trailing;
  final bool showCloseButton;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
      child: Row(
        children: [
          if (leading != null) ...[
            IconTheme(
              data: IconThemeData(color: Theme.of(context).colorScheme.primary),
              child: leading!,
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ...trailing,
          if (showCloseButton)
            IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            ),
        ],
      ),
    );
  }
}

class BottomSheetActionBar extends StatelessWidget {
  const BottomSheetActionBar({
    super.key,
    required this.secondaryLabel,
    required this.onSecondaryPressed,
    required this.primaryLabel,
    required this.onPrimaryPressed,
  });

  final String secondaryLabel;
  final VoidCallback onSecondaryPressed;
  final String primaryLabel;
  final VoidCallback? onPrimaryPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: onSecondaryPressed,
                  child: Text(secondaryLabel),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: onPrimaryPressed,
                  child: Text(primaryLabel),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class BottomSheetMenu extends StatelessWidget {
  const BottomSheetMenu({
    super.key,
    this.header,
    required this.children,
    this.bottomSpacing = 8,
  });

  final Widget? header;
  final List<Widget> children;
  final double bottomSpacing;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null) header!,
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...children,
                  SizedBox(height: bottomSpacing),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 显示响应式 BottomSheet 的辅助方法
/// maxHeightListenable 随视频区域变化重新限高。
Future<T?> showResponsiveBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double? maxWidth,
  double? maxHeight,
  ValueListenable<double>? maxHeightListenable,
  bool isScrollControlled = true,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  final navigator = Navigator.of(context);
  final capturedThemes = InheritedTheme.capture(
    from: context,
    to: navigator.context,
  );

  final route = ResponsiveBottomSheetRoute<T>(
    builder: builder,
    capturedThemes: capturedThemes,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    maxHeightListenable: maxHeightListenable,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    disableAnimations: MediaQuery.disableAnimationsOf(context),
  );
  final shell = AppNavigationScope.maybeOf(context);
  final result = navigator.push<T>(route);
  if (shell != null) {
    shell.registerSheet(route, navigator, route.coveredByPage);
    unawaited(route.completed.then((_) => shell.unregisterSheet(route)));
  }
  return result;
}

class ResponsiveBottomSheetRoute<T> extends PopupRoute<T> {
  ResponsiveBottomSheetRoute({
    required this.builder,
    required this.capturedThemes,
    required this.barrierLabel,
    required this.maxWidth,
    required this.maxHeight,
    required this.maxHeightListenable,
    required this.isScrollControlled,
    required this.isDismissible,
    required this.enableDrag,
    required this.disableAnimations,
  });

  final WidgetBuilder builder;
  final CapturedThemes capturedThemes;
  final double? maxWidth;
  final double? maxHeight;
  final ValueListenable<double>? maxHeightListenable;
  final bool isScrollControlled;
  final bool isDismissible;
  final bool enableDrag;
  final bool disableAnimations;
  Animation<double>? _routeAnimation;
  CurvedAnimation? _curvedAnimation;
  CurvedAnimation? _dragCurvedAnimation;
  ProxyAnimation? _sheetAnimation;
  ShapeBorderClipper _panelClipper = const ShapeBorderClipper(
    shape: RoundedRectangleBorder(),
  );
  final _panelKey = GlobalKey();
  final _panelSizeChanges = ValueNotifier(0);
  final coveredByPage = ValueNotifier(false);

  Listenable get panelSizeChanges => _panelSizeChanges;

  Path? get panelPath {
    final context = _panelKey.currentContext;
    if (context is! RenderObjectElement || !context.mounted) return null;
    final panel = context.renderObject;
    if (panel is! RenderBox || !panel.attached || !panel.hasSize) return null;
    return _panelClipper
        .getClip(panel.size)
        .transform(panel.getTransformTo(null).storage);
  }

  @override
  final String barrierLabel;

  @override
  Color get barrierColor => Colors.black54;

  @override
  bool get barrierDismissible => isDismissible;

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    coveredByPage.value = nextRoute is PageRoute<dynamic>;
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    super.didPopNext(nextRoute);
    if (nextRoute is PageRoute<dynamic>) coveredByPage.value = false;
  }

  @override
  Duration get transitionDuration =>
      disableAnimations ? Duration.zero : const Duration(milliseconds: 250);

  @override
  Duration get reverseTransitionDuration =>
      disableAnimations ? Duration.zero : const Duration(milliseconds: 200);

  @override
  AnimationController createAnimationController() {
    final controller = BottomSheet.createAnimationController(navigator!);
    if (disableAnimations) {
      controller
        ..duration = Duration.zero
        ..reverseDuration = Duration.zero;
    }
    return controller;
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final sheetAnimation = _getSheetAnimation(animation);
    final mediaQuery = MediaQuery.of(context);
    final shellMediaQuery = context
        .dependOnInheritedWidgetOfExactType<AppNavigationScope>()
        ?.mediaQuery;
    return capturedThemes.wrap(
      Semantics(
        scopesRoute: true,
        namesRoute: true,
        label: MaterialLocalizations.of(context).dialogLabel,
        explicitChildNodes: true,
        child: MediaQuery(
          data:
              shellMediaQuery == null ||
                  mediaQuery.orientation == Orientation.landscape
              ? mediaQuery
              : mediaQuery.copyWith(
                  padding: mediaQuery.padding.copyWith(
                    bottom: shellMediaQuery.padding.bottom,
                  ),
                  viewPadding: mediaQuery.viewPadding.copyWith(
                    bottom: shellMediaQuery.viewPadding.bottom,
                  ),
                ),
          child: ResponsiveBottomSheet._modal(
            animationController: controller!,
            slideAnimation: sheetAnimation,
            onClosing: () {
              if (isCurrent) {
                navigator?.pop<T>();
              }
            },
            onDragStart: _handleDragStart,
            onDragEnd: _handleDragEnd,
            panelKey: _panelKey,
            onPanelSizeChanged: () => _panelSizeChanges.value++,
            isScrollControlled: isScrollControlled,
            enableDrag: enableDrag,
            disableAnimations: disableAnimations,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            maxHeightListenable: maxHeightListenable,
            child: Builder(
              builder: (context) {
                final material = context
                    .findAncestorWidgetOfExactType<Material>()!;
                _panelClipper = ShapeBorderClipper(
                  shape: material.shape ?? const RoundedRectangleBorder(),
                  textDirection: Directionality.of(context),
                );
                return builder(context);
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }

  Animation<double> _getSheetAnimation(Animation<double> animation) {
    if (_routeAnimation != animation) {
      _sheetAnimation?.parent = null;
      _dragCurvedAnimation?.dispose();
      _curvedAnimation?.dispose();
      _routeAnimation = animation;
      _curvedAnimation = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeOutCubic,
      );
      _sheetAnimation = ProxyAnimation(_curvedAnimation);
    }
    return _sheetAnimation!;
  }

  void _handleDragStart(DragStartDetails details) {
    _dragCurvedAnimation?.dispose();
    _dragCurvedAnimation = null;
    _sheetAnimation?.parent = _routeAnimation;
  }

  void _handleDragEnd(DragEndDetails details, {required bool isClosing}) {
    final animation = _routeAnimation;
    if (animation == null) return;

    _dragCurvedAnimation?.dispose();
    final progress = animation.value;
    _dragCurvedAnimation = CurvedAnimation(
      parent: animation,
      curve: Split(progress, endCurve: Curves.easeOutCubic),
      reverseCurve: Split(progress, endCurve: Curves.easeOutCubic),
    );
    _sheetAnimation?.parent = _dragCurvedAnimation;
  }

  @override
  void dispose() {
    coveredByPage.dispose();
    _panelSizeChanges.dispose();
    _sheetAnimation?.parent = null;
    _dragCurvedAnimation?.dispose();
    _curvedAnimation?.dispose();
    super.dispose();
  }
}

Future<T?> showBottomSheetMenu<T>({
  required BuildContext context,
  required List<Widget> children,
  double? maxWidth,
  double? maxHeight,
}) {
  return showResponsiveBottomSheet<T>(
    context: context,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    builder: (context) => BottomSheetMenu(children: children),
  );
}
