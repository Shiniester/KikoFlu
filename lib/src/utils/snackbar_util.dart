import 'dart:async';

import 'package:flutter/material.dart';

import 'global_keys.dart';

/// 统一的顶部轻量提示控制器
class AppNoticeController {
  final VoidCallback _close;
  final Completer<void> _closedCompleter = Completer<void>();

  AppNoticeController(this._close);

  void close() => _close();

  Future<void> get closed => _closedCompleter.future;

  void completeClosed() {
    if (!_closedCompleter.isCompleted) {
      _closedCompleter.complete();
    }
  }
}

/// 统一的顶部悬浮提示组件
class TopFloatingNoticeWidget extends StatefulWidget {
  final Widget content;
  final Duration duration;
  final Color? backgroundColor;
  final SnackBarAction? action;
  final bool showCloseIcon;
  final VoidCallback onDismissed;
  final double topOffset;

  const TopFloatingNoticeWidget({
    super.key,
    required this.content,
    required this.duration,
    this.backgroundColor,
    this.action,
    this.showCloseIcon = false,
    required this.onDismissed,
    this.topOffset = 16.0,
  });

  @override
  State<TopFloatingNoticeWidget> createState() =>
      TopFloatingNoticeWidgetState();
}

class TopFloatingNoticeWidgetState extends State<TopFloatingNoticeWidget>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;
  Timer? _timer;
  Offset _dragOffset = Offset.zero;
  bool _isExiting = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0.0, -1.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ));
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    _controller.forward().then((_) {
      if (mounted) {
        _startTimer();
      }
    });
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer(widget.duration, () {
      dismiss();
    });
  }

  void _pauseTimer() {
    _timer?.cancel();
  }

  Future<void> dismiss({bool immediate = false}) async {
    if (_isExiting) return;
    _isExiting = true;
    _timer?.cancel();

    if (immediate || !mounted) {
      widget.onDismissed();
      return;
    }

    try {
      await _controller.reverse();
    } finally {
      if (mounted) widget.onDismissed();
    }
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (_isExiting) return;
    _pauseTimer();
    setState(() {
      final newDy = _dragOffset.dy + details.delta.dy;
      // 向下拉动增加阻尼，只响应纵向手势
      final clampedDy = newDy > 0 ? newDy * 0.2 : newDy;
      _dragOffset = Offset(0, clampedDy);
    });
  }

  void _handlePanEnd(DragEndDetails details) {
    if (_isExiting) return;
    final vy = details.velocity.pixelsPerSecond.dy;

    // 仅支持向上滑动划走
    if (_dragOffset.dy < -20 || vy < -200) {
      dismiss();
      return;
    }

    // 回弹复位
    final springController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    final start = _dragOffset;
    final springAnim = Tween<Offset>(begin: start, end: Offset.zero).animate(
      CurvedAnimation(parent: springController, curve: Curves.easeOutCubic),
    );
    springAnim.addListener(() {
      if (mounted) {
        setState(() {
          _dragOffset = springAnim.value;
        });
      }
    });
    springController.forward().then((_) {
      springController.dispose();
      if (mounted) {
        _startTimer();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final bg = widget.backgroundColor ?? colorScheme.secondaryContainer;

    // 针对移动端状态栏避让，桌面端 safeTop 为 0 时保持 topOffset 间距
    final mediaQuery = MediaQuery.maybeOf(context);
    final view = View.maybeOf(context);
    final safeTop = (mediaQuery != null && mediaQuery.padding.top > 0)
        ? mediaQuery.padding.top
        : (view != null ? view.viewPadding.top / view.devicePixelRatio : 0.0);
    final effectiveTop = safeTop + widget.topOffset;

    return Positioned(
      top: effectiveTop,
      left: 0,
      right: 0,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420.0),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: SlideTransition(
              position: _slideAnimation,
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: Transform.translate(
                  offset: _dragOffset,
                  child: MouseRegion(
                    onEnter: (_) => _pauseTimer(),
                    onExit: (_) => _startTimer(),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: _handlePanUpdate,
                      onPanEnd: _handlePanEnd,
                      onTap: () {}, // 点击主体不触发关闭，防止误触
                      child: Material(
                        elevation: 6,
                        color: bg,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16.0,
                            vertical: 12.0,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Expanded(
                                child: DefaultTextStyle(
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                        color: colorScheme.onSecondaryContainer,
                                      ) ??
                                      const TextStyle(),
                                  child: widget.content,
                                ),
                              ),
                              if (widget.action != null) ...[
                                const SizedBox(width: 8),
                                TextButton(
                                  onPressed: () {
                                    widget.action!.onPressed();
                                    dismiss();
                                  },
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    minimumSize: const Size(0, 32),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    foregroundColor: widget.action!.textColor,
                                  ),
                                  child: Text(widget.action!.label),
                                ),
                              ],
                              if (widget.showCloseIcon) ...[
                                const SizedBox(width: 4),
                                InkWell(
                                  onTap: () => dismiss(),
                                  borderRadius: BorderRadius.circular(12),
                                  child: const Padding(
                                    padding: EdgeInsets.all(4.0),
                                    child: Icon(Icons.close, size: 18),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NoticeSession {
  final OverlayEntry entry;
  final void Function({bool immediate}) dismiss;
  final AppNoticeController controller;
  bool _removed = false;

  _NoticeSession({
    required this.entry,
    required this.dismiss,
    required this.controller,
  });

  void remove() {
    if (!_removed) {
      _removed = true;
      entry.remove();
      controller.completeClosed();
    }
  }
}

/// 顶部统一浮动提示管理器
class AppFloatingNotice {
  AppFloatingNotice._();

  static _NoticeSession? _currentSession;

  static OverlayState? _findOverlay(BuildContext? context) {
    if (context != null) {
      try {
        final overlay =
            Overlay.maybeOf(context, rootOverlay: true) ?? Overlay.maybeOf(context);
        if (overlay != null) return overlay;
      } catch (_) {}
    }
    final navOverlay = rootNavigatorKey.currentState?.overlay;
    if (navOverlay != null) return navOverlay;
    final rootContext = rootScaffoldMessengerKey.currentContext;
    if (rootContext != null) {
      try {
        final overlay = Overlay.maybeOf(rootContext, rootOverlay: true) ??
            Overlay.maybeOf(rootContext);
        if (overlay != null) return overlay;
      } catch (_) {}
    }
    return null;
  }

  static AppNoticeController? show(
    BuildContext context, {
    required Widget content,
    required Duration duration,
    Color? backgroundColor,
    SnackBarAction? action,
    bool showCloseIcon = false,
    ScaffoldMessengerState? messengerOverride,
  }) {
    // 立即顶掉当前显示的旧提示
    _currentSession?.dismiss(immediate: true);
    _currentSession = null;

    final overlay = _findOverlay(context);
    if (overlay == null) return null;

    late final _NoticeSession session;
    final key = GlobalKey<TopFloatingNoticeWidgetState>();
    late final AppNoticeController controller;

    controller = AppNoticeController(() {
      session.dismiss();
    });

    final entry = OverlayEntry(
      builder: (_) => TopFloatingNoticeWidget(
        key: key,
        content: content,
        duration: duration,
        backgroundColor: backgroundColor,
        action: action,
        showCloseIcon: showCloseIcon,
        onDismissed: () {
          session.remove();
          if (_currentSession == session) {
            _currentSession = null;
          }
        },
      ),
    );

    session = _NoticeSession(
      entry: entry,
      dismiss: ({bool immediate = false}) {
        if (immediate) {
          session.remove();
        } else {
          key.currentState?.dismiss();
        }
      },
      controller: controller,
    );

    _currentSession = session;
    overlay.insert(entry);

    return controller;
  }

  static void hide() {
    _currentSession?.dismiss();
  }

  static void clearAll() {
    _currentSession?.dismiss(immediate: true);
    _currentSession = null;
  }
}

/// SnackBar 工具类，提供统一的提示风格
class SnackBarUtil {
  SnackBarUtil._();

  /// 兼容旧代码中直接构造的 SnackBar，并尽量转成统一样式。
  static void showFromSnackBar(
    BuildContext context,
    SnackBar snackBar, {
    ScaffoldMessengerState? fallbackMessenger,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    try {
      final message = _extractMessage(snackBar.content);
      if (message == null || message.isEmpty) {
        AppFloatingNotice.show(
          context,
          content: snackBar.content,
          duration: snackBar.duration,
          backgroundColor: snackBar.backgroundColor,
          action: snackBar.action,
          showCloseIcon: snackBar.showCloseIcon ?? false,
          messengerOverride: fallbackMessenger,
        );
        return;
      }

      final backgroundColor = snackBar.backgroundColor;
      final duration = snackBar.duration;
      final colorScheme = Theme.of(context).colorScheme;

      if (snackBar.action != null) {
        AppFloatingNotice.show(
          context,
          content: snackBar.content,
          duration: duration,
          backgroundColor: backgroundColor,
          action: snackBar.action,
          showCloseIcon: snackBar.showCloseIcon ?? false,
          messengerOverride: fallbackMessenger,
        );
        return;
      }

      if (backgroundColor == Colors.red ||
          backgroundColor == colorScheme.error) {
        showError(context, message, duration: duration);
      } else if (backgroundColor == Colors.green) {
        showSuccess(context, message, duration: duration);
      } else if (backgroundColor == Colors.orange) {
        showWarning(context, message, duration: duration);
      } else {
        showInfo(context, message, duration: duration);
      }
    } catch (error, stackTrace) {
      onError?.call(error, stackTrace);
    }
  }

  static String? _extractMessage(Widget content) {
    if (content is Text) {
      return content.data;
    }

    if (content is Row) {
      for (final child in content.children) {
        if (child is Text) {
          return child.data;
        }

        if (child is Expanded && child.child is Text) {
          return (child.child as Text).data;
        }
      }
    }

    return null;
  }

  /// 显示成功提示
  static void showSuccess(
    BuildContext context,
    String message, {
    Duration duration = const Duration(milliseconds: 1200),
  }) {
    AppFloatingNotice.show(
      context,
      content: Row(
        children: [
          Icon(
            Icons.check_circle_outline,
            color: Theme.of(context).colorScheme.onPrimary,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.onPrimary),
            ),
          ),
        ],
      ),
      backgroundColor: Theme.of(context).colorScheme.primary,
      duration: duration,
    );
  }

  /// 显示错误提示
  static void showError(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
  }) {
    AppFloatingNotice.show(
      context,
      content: Row(
        children: [
          Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.onError,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.onError),
            ),
          ),
        ],
      ),
      backgroundColor: Theme.of(context).colorScheme.error,
      duration: duration,
    );
  }

  /// 显示警告提示
  static void showWarning(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final warningColor = colorScheme.tertiary;
    final onWarningColor = colorScheme.onTertiary;

    AppFloatingNotice.show(
      context,
      content: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: onWarningColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: TextStyle(color: onWarningColor)),
          ),
        ],
      ),
      backgroundColor: warningColor,
      duration: duration,
    );
  }

  /// 显示信息提示
  static void showInfo(
    BuildContext context,
    String message, {
    Duration duration = const Duration(milliseconds: 1200),
  }) {
    AppFloatingNotice.show(
      context,
      content: Row(
        children: [
          Icon(
            Icons.info_outline,
            color: Theme.of(context).colorScheme.onSecondaryContainer,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
      backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
      duration: duration,
    );
  }

  /// 显示加载提示
  static void showLoading(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 30),
  }) {
    AppFloatingNotice.show(
      context,
      content: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
      backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
      duration: duration,
    );
  }

  /// 隐藏当前显示的提示
  static void hide([BuildContext? context]) {
    AppFloatingNotice.hide();
    if (context != null) {
      ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    }
  }

  /// 清除所有提示
  static void clearAll([BuildContext? context]) {
    AppFloatingNotice.clearAll();
    if (context != null) {
      ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    }
  }
}
