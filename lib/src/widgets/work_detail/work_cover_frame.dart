import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../utils/age_rating.dart';
import '../age_rating_chip.dart';
import '../privacy_blur_cover.dart';

const double _coverBadgeInset = 12;
const double workCoverDetailRadius = 12;
const double workCoverCompactRadius = 8;

class WorkCoverHeroFrame extends StatelessWidget {
  const WorkCoverHeroFrame({
    super.key,
    required this.heroTag,
    required this.child,
    this.cornerRadius = workCoverDetailRadius,
    this.enabled = true,
  });

  final Object heroTag;
  final Widget child;
  final double cornerRadius;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final payload = _WorkCoverHeroPayload(
      cornerRadius: cornerRadius,
      child: child,
    );
    if (!enabled || MediaQuery.disableAnimationsOf(context)) return payload;
    return Hero(
      tag: heroTag,
      createRectTween: (begin, end) => RectTween(begin: begin, end: end),
      flightShuttleBuilder: _workCoverFlightShuttle,
      child: payload,
    );
  }
}

class _WorkCoverHeroPayload extends StatelessWidget {
  const _WorkCoverHeroPayload({
    required this.cornerRadius,
    required this.child,
  });

  final double cornerRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(cornerRadius),
    child: child,
  );
}

Widget _workCoverFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final from =
      ((fromHeroContext.widget as Hero).child as _WorkCoverHeroPayload);
  final to = ((toHeroContext.widget as Hero).child as _WorkCoverHeroPayload);
  return AnimatedBuilder(
    animation: animation,
    child: from.child,
    builder: (context, child) => ClipRRect(
      borderRadius: BorderRadius.circular(
        Tween<double>(
          begin: from.cornerRadius,
          end: to.cornerRadius,
        ).evaluate(animation),
      ),
      child: child,
    ),
  );
}

class WorkCoverFrame extends StatelessWidget {
  const WorkCoverFrame({
    super.key,
    required this.heroTag,
    required this.isLandscape,
    required this.layers,
    this.showSubtitleBadge = false,
    this.showAgeRating = false,
    this.age,
    this.onTap,
  });

  final Object heroTag;
  final bool isLandscape;
  final List<Widget> layers;
  final bool showSubtitleBadge;
  final bool showAgeRating;
  final String? age;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mediaSize = MediaQuery.sizeOf(context);

    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: WorkCoverHeroFrame(
          heroTag: heroTag,
          cornerRadius: workCoverDetailRadius,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: isLandscape ? null : double.infinity,
              constraints: BoxConstraints(
                maxHeight: isLandscape ? mediaSize.height * 0.8 : 500,
                maxWidth: isLandscape
                    ? mediaSize.width * 0.45
                    : double.infinity,
              ),
              child: PrivacyBlurCover(
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    ...layers,
                    if (showAgeRating && AgeRatingFormatter.hasValue(age))
                      Positioned(
                        left: _coverBadgeInset,
                        bottom: _coverBadgeInset,
                        child: AgeRatingChip(
                          key: const ValueKey('work-cover-age-badge'),
                          age: age,
                          compact: true,
                        ),
                      ),
                    if (showSubtitleBadge) const _SubtitleBadge(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SubtitleBadge extends StatelessWidget {
  const _SubtitleBadge();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Positioned(
      right: _coverBadgeInset,
      bottom: _coverBadgeInset,
      child: Container(
        key: const ValueKey('work-cover-subtitle-badge'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: colorScheme.primary,
          borderRadius: BorderRadius.circular(6),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          S.of(context).subtitleBadge,
          style: TextStyle(
            color: colorScheme.onPrimary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            height: 1.1,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
