import 'dart:ui';

import 'package:flutter/material.dart';

/// Shared, bounded backdrop treatment for surfaces inside the player.
///
/// A [BackdropGroup] around the player lets sibling surfaces reuse the same
/// backdrop input. Keep the blur modest: artwork colours are already supplied
/// by the static player gradient and do not need a full-screen live blur.
class PlayerGlassSurface extends StatelessWidget {
  const PlayerGlassSurface({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.onTap,
    this.sigma = 6,
    this.tint,
    this.borderColor,
    this.enabled = true,
    this.grouped = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadiusGeometry borderRadius;
  final VoidCallback? onTap;
  final double sigma;
  final Color? tint;
  final Color? borderColor;
  final bool enabled;
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final content = Padding(padding: padding, child: child);
    final interactive = Material(
      color: Colors.transparent,
      child: onTap == null ? content : InkWell(onTap: onTap, child: content),
    );

    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: tint ?? colors.onSurface.withValues(alpha: 0.075),
        borderRadius: borderRadius,
        border: Border.all(
          color: borderColor ?? colors.onSurface.withValues(alpha: 0.16),
        ),
      ),
      child: interactive,
    );
    final filter = ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: borderRadius,
        child: grouped
            ? BackdropFilter.grouped(
                filter: filter,
                enabled: enabled,
                child: surface,
              )
            : BackdropFilter(filter: filter, enabled: enabled, child: surface),
      ),
    );
  }
}

/// Gives grouped player glass surfaces a shared backdrop source.
class PlayerBackdropGroup extends StatelessWidget {
  const PlayerBackdropGroup({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => BackdropGroup(child: child);
}

/// Alert-style player dialog with the same glass treatment as player sheets.
class PlayerGlassAlertDialog extends StatelessWidget {
  const PlayerGlassAlertDialog({
    super.key,
    this.title,
    this.content,
    this.actions = const [],
    this.maxWidth,
    this.contentPadding,
  });

  final Widget? title;
  final Widget? content;
  final List<Widget> actions;
  final double? maxWidth;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width =
        maxWidth ??
        (media.orientation == Orientation.landscape
            ? media.size.width * 0.58
            : media.size.width * 0.86);
    return PlayerBackdropGroup(
      child: Dialog(
        elevation: 0,
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: width,
            maxHeight: media.size.height * 0.82,
          ),
          child: PlayerGlassSurface(
            borderRadius: BorderRadius.circular(16),
            grouped: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
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
                          const EdgeInsets.fromLTRB(20, 14, 20, 16),
                      child: DefaultTextStyle(
                        style: Theme.of(context).textTheme.bodyMedium!,
                        child: content!,
                      ),
                    ),
                  ),
                if (actions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: OverflowBar(
                      alignment: MainAxisAlignment.end,
                      spacing: 8,
                      children: actions,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
