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
    final clippedSurface = ClipRRect(
      borderRadius: borderRadius,
      child: surface,
    );
    if (!enabled) {
      return RepaintBoundary(child: clippedSurface);
    }

    final filter = ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: borderRadius,
        child: grouped
            ? BackdropFilter.grouped(filter: filter, child: surface)
            : BackdropFilter(filter: filter, child: surface),
      ),
    );
  }
}

/// One-pass, high-contrast glass used by temporary player overlays.
///
/// The stronger perceived blur comes from one bounded sigma-10 backdrop pass
/// plus a dark tint. Children should use [PlayerGlassMaterial] instead of
/// adding another backdrop filter.
class PlayerTransientGlassSurface extends StatelessWidget {
  const PlayerTransientGlassSurface({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.onTap,
  });

  static const double blurSigma = 10;
  static const Color surfaceTint = Color(0x75101215);
  static const Color surfaceBorder = Color(0x24FFFFFF);

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadiusGeometry borderRadius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final baseScheme = baseTheme.colorScheme;
    final foregroundTheme = baseTheme.copyWith(
      brightness: Brightness.dark,
      colorScheme: baseScheme.copyWith(
        brightness: Brightness.dark,
        surface: const Color(0xFF17191D),
        onSurface: Colors.white,
        onSurfaceVariant: const Color(0xBFFFFFFF),
        outline: const Color(0x3DFFFFFF),
        outlineVariant: const Color(0x24FFFFFF),
      ),
      iconTheme: baseTheme.iconTheme.copyWith(color: Colors.white),
      textTheme: baseTheme.textTheme.apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
      ),
    );
    return Theme(
      data: foregroundTheme,
      child: PlayerGlassSurface(
        borderRadius: borderRadius,
        grouped: false,
        sigma: blurSigma,
        tint: surfaceTint,
        borderColor: surfaceBorder,
        padding: padding,
        onTap: onTap,
        child: child,
      ),
    );
  }
}

/// Semi-transparent material for cards inside a transient glass overlay.
/// It deliberately does not create another backdrop filter.
class PlayerGlassMaterial extends StatelessWidget {
  const PlayerGlassMaterial({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.onTap,
    this.tint,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadiusGeometry borderRadius;
  final VoidCallback? onTap;
  final Color? tint;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PlayerGlassSurface(
      enabled: false,
      grouped: false,
      borderRadius: borderRadius,
      tint: tint ?? colors.onSurface.withValues(alpha: 0.075),
      borderColor: borderColor ?? colors.onSurface.withValues(alpha: 0.10),
      padding: padding,
      onTap: onTap,
      child: child,
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
          child: PlayerTransientGlassSurface(
            borderRadius: BorderRadius.circular(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                    child: DefaultTextStyle(
                      style: Theme.of(
                        context,
                      ).textTheme.titleLarge!.copyWith(color: Colors.white),
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
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium!.copyWith(color: Colors.white),
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
