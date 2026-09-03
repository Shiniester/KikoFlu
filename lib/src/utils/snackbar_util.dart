import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'global_keys.dart';

/// Central Material 3 transient notice. Its placement depends only on the
/// viewport and safe area, so Mini Player and navigation rebuilds never move
/// an already visible notice.
class AppFloatingNotice {
  AppFloatingNotice._();

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? show(
    BuildContext context, {
    required Widget content,
    required Duration duration,
    Color? backgroundColor,
    SnackBarAction? action,
    bool showCloseIcon = false,
    ScaffoldMessengerState? messengerOverride,
  }) {
    final messenger =
        messengerOverride ??
        ScaffoldMessenger.maybeOf(context) ??
        rootScaffoldMessengerKey.currentState;
    if (messenger == null) return null;
    final mediaQuery = MediaQuery.maybeOf(context);
    final width = mediaQuery?.size.width ?? 360;
    final height = mediaQuery?.size.height ?? 800;
    final safeBottom = mediaQuery?.viewPadding.bottom ?? 0;
    final horizontal = math.max(16.0, (width - 420) / 2);
    final viewportOffset = (height * 0.18).clamp(88.0, 144.0);
    messenger.removeCurrentSnackBar(reason: SnackBarClosedReason.hide);
    return messenger.showSnackBar(
      SnackBar(
        content: content,
        duration: duration,
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(
          horizontal,
          0,
          horizontal,
          safeBottom + viewportOffset,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.antiAlias,
        elevation: 6,
        backgroundColor: backgroundColor,
        action: action,
        showCloseIcon: showCloseIcon,
      ),
    );
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
    Duration duration = const Duration(seconds: 2),
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
    Duration duration = const Duration(seconds: 4),
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
    Duration duration = const Duration(seconds: 3),
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    // 使用 tertiary 或 secondary 作为警告色
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
    Duration duration = const Duration(seconds: 2),
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

  /// 隐藏当前显示的 SnackBar
  static void hide(BuildContext context) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  /// 清除所有 SnackBar
  static void clearAll(BuildContext context) {
    ScaffoldMessenger.of(context).clearSnackBars();
  }
}
