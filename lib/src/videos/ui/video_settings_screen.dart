import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../widgets/settings_section.dart';
import '../video_card_display_provider.dart';
import 'video_playback_settings_screen.dart';

class VideoSettingsScreen extends StatelessWidget {
  const VideoSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => SettingsSubpageScaffold(
    title: S.of(context).videoSettings,
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SettingsSectionList(
          children: [
            SettingsNavigationTile(
              icon: Icons.play_circle_outline,
              title: S.of(context).videoPlayerSettings,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const VideoPlaybackSettingsRoute(),
                ),
              ),
            ),
            SettingsNavigationTile(
              icon: Icons.dashboard_customize,
              title: S.of(context).uiSettings,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const VideoUiSettingsScreen(),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class VideoUiSettingsScreen extends StatelessWidget {
  const VideoUiSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => SettingsSubpageScaffold(
    title: S.of(context).uiSettings,
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SettingsSectionList(
          children: [
            SettingsNavigationTile(
              icon: Icons.grid_view,
              title: S.of(context).workCardDisplaySettings,
              subtitle: S.of(context).workCardDisplaySubtitle,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const VideoCardDisplaySettingsScreen(),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class VideoCardDisplaySettingsScreen extends ConsumerWidget {
  const VideoCardDisplaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visibleFields = ref.watch(videoCardDisplayProvider);

    return SettingsSubpageScaffold(
      title: S.of(context).workCardDisplaySettings,
      onRestoreDefaults: () => confirmAndRestoreSettingsDefaults(
        context: context,
        restore: () =>
            ref.read(videoCardDisplayProvider.notifier).resetToDefault(),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SettingsSectionList(
            children: [
              SettingsSwitchTile(
                icon: Icons.access_time,
                title: S.of(context).durationInfo,
                value: visibleFields.contains(VideoCardField.duration),
                onChanged: (value) => ref
                    .read(videoCardDisplayProvider.notifier)
                    .setVisible(VideoCardField.duration, value),
              ),
              SettingsSwitchTile(
                icon: Icons.calendar_today_outlined,
                title: S.of(context).releaseDateInfo,
                value: visibleFields.contains(VideoCardField.releaseDate),
                onChanged: (value) => ref
                    .read(videoCardDisplayProvider.notifier)
                    .setVisible(VideoCardField.releaseDate, value),
              ),
              SettingsSwitchTile(
                icon: Icons.closed_caption,
                title: S.of(context).subtitleTagLabel,
                value: visibleFields.contains(VideoCardField.subtitleTag),
                onChanged: (value) => ref
                    .read(videoCardDisplayProvider.notifier)
                    .setVisible(VideoCardField.subtitleTag, value),
              ),
              SettingsSwitchTile(
                icon: Icons.no_encryption_outlined,
                title: S.of(context).videoUncensored,
                value: visibleFields.contains(VideoCardField.uncensoredTag),
                onChanged: (value) => ref
                    .read(videoCardDisplayProvider.notifier)
                    .setVisible(VideoCardField.uncensoredTag, value),
              ),
              SettingsSwitchTile(
                icon: Icons.business_outlined,
                title: S.of(context).videoCardMakers,
                value: visibleFields.contains(VideoCardField.makers),
                onChanged: (value) => ref
                    .read(videoCardDisplayProvider.notifier)
                    .setVisible(VideoCardField.makers, value),
              ),
              SettingsSwitchTile(
                icon: Icons.label_outline,
                title: S.of(context).videoCardLabels,
                value: visibleFields.contains(VideoCardField.labels),
                onChanged: (value) => ref
                    .read(videoCardDisplayProvider.notifier)
                    .setVisible(VideoCardField.labels, value),
              ),
              SettingsSwitchTile(
                icon: Icons.movie_filter_outlined,
                title: S.of(context).series,
                value: visibleFields.contains(VideoCardField.series),
                onChanged: (value) => ref
                    .read(videoCardDisplayProvider.notifier)
                    .setVisible(VideoCardField.series, value),
              ),
              SettingsSwitchTile(
                icon: Icons.edit_outlined,
                title: S.of(context).videoCardDirectors,
                value: visibleFields.contains(VideoCardField.directors),
                onChanged: (value) => ref
                    .read(videoCardDisplayProvider.notifier)
                    .setVisible(VideoCardField.directors, value),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
