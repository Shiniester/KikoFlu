import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../providers/work_card_display_provider.dart';
import '../widgets/settings_section.dart';

class WorkCardDisplaySettingsScreen extends ConsumerWidget {
  const WorkCardDisplaySettingsScreen({super.key});

  Future<void> _resetToDefault(BuildContext context, WidgetRef ref) async {
    await confirmAndRestoreSettingsDefaults(
      context: context,
      restore: ref.read(workCardDisplayProvider.notifier).resetToDefault,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(workCardDisplayProvider);
    final notifier = ref.read(workCardDisplayProvider.notifier);

    return SettingsSubpageScaffold(
      title: S.of(context).workCardDisplaySettings,
      onRestoreDefaults: () => _resetToDefault(context, ref),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SettingsSectionList(
            children: [
              SettingsSwitchTile(
                icon: Icons.star,
                title: S.of(context).ratingInfo,
                subtitle: S.of(context).showRatingAndReviewCount,
                value: settings.showRating,
                onChanged: (_) => notifier.toggleRating(),
              ),
              SettingsSwitchTile(
                icon: Icons.attach_money,
                title: S.of(context).priceInfo,
                subtitle: S.of(context).showWorkPrice,
                value: settings.showPrice,
                onChanged: (_) => notifier.togglePrice(),
              ),
              SettingsSwitchTile(
                icon: Icons.access_time,
                title: S.of(context).durationInfo,
                subtitle: S.of(context).showWorkTotalDuration,
                value: settings.showDuration,
                onChanged: (_) => notifier.toggleDuration(),
              ),
              SettingsSwitchTile(
                icon: Icons.shopping_cart,
                title: S.of(context).salesInfo,
                subtitle: S.of(context).showWorkSalesCount,
                value: settings.showSales,
                onChanged: (_) => notifier.toggleSales(),
              ),
              SettingsSwitchTile(
                icon: Icons.calendar_today,
                title: S.of(context).releaseDateInfo,
                subtitle: S.of(context).showWorkReleaseDate,
                value: settings.showReleaseDate,
                onChanged: (_) => notifier.toggleReleaseDate(),
              ),
              SettingsSwitchTile(
                icon: Icons.group,
                title: S.of(context).circleInfo,
                subtitle: S.of(context).showWorkCircle,
                value: settings.showCircle,
                onChanged: (_) => notifier.toggleCircle(),
              ),
              SettingsSwitchTile(
                icon: Icons.closed_caption,
                title: S.of(context).subtitleTagLabel,
                subtitle: S.of(context).showSubtitleTagOnCard,
                value: settings.showSubtitleTag,
                onChanged: (_) => notifier.toggleSubtitleTag(),
              ),
              SettingsSwitchTile(
                icon: Icons.person,
                title: S.of(context).ageRatingLabel,
                subtitle: S.of(context).showAgeRatingOnCard,
                value: settings.showAgeRating,
                onChanged: (_) => notifier.toggleAgeRating(),
              ),
              SettingsSwitchTile(
                icon: Icons.label_outline,
                title: S.of(context).userAddedTagsLabel,
                subtitle: S.of(context).showUserAddedTagsOnCard,
                value: settings.showUserAddedTags,
                onChanged: (_) => notifier.toggleUserAddedTags(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
