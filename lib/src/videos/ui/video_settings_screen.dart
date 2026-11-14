import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../providers/unified_search_history_provider.dart';
import '../../providers/works_provider.dart' show LayoutType;
import '../../utils/snackbar_util.dart';
import '../../utils/string_utils.dart';
import '../../widgets/radio_option_group.dart';
import '../../widgets/settings_option_dialog.dart';
import '../../widgets/settings_section.dart';
import '../video_browse_preferences.dart';
import '../video_card_display_provider.dart';
import '../video_download_task.dart';
import '../video_downloads.dart';
import '../video_providers.dart';
import '../video_search_history.dart';
import 'jable_account_screen.dart';
import 'video_account_screen.dart';
import 'video_downloads_screen.dart';
import 'video_playback_settings_screen.dart';

class VideoSettingsScreen extends ConsumerStatefulWidget {
  const VideoSettingsScreen({super.key});

  @override
  ConsumerState<VideoSettingsScreen> createState() =>
      _VideoSettingsScreenState();
}

class _VideoSettingsScreenState extends ConsumerState<VideoSettingsScreen> {
  int? _completedBytes;
  bool _sizeLoading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDownloadSize());
  }

  Future<void> _loadDownloadSize() async {
    final downloads = ref.read(videoDownloadsProvider);
    try {
      await downloads.initialize();
      var total = 0;
      for (final task in downloads.tasks) {
        if (task.status != VideoDownloadStatus.completed) continue;
        final path = task.localPath;
        if (path == null) continue;
        final file = File(path);
        if (task.isHls) {
          final directory = file.parent;
          if (await directory.exists()) {
            await for (final entity in directory.list(
              recursive: true,
              followLinks: false,
            )) {
              if (entity is File) total += await entity.length();
            }
          }
        } else if (await file.exists()) {
          total += await file.length();
        }
      }
      if (!mounted) return;
      setState(() {
        _completedBytes = total;
        _sizeLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _completedBytes = null;
        _sizeLoading = false;
      });
    }
  }

  String _downloadsSubtitle(S s, VideoDownloads downloads) {
    final completed = downloads.tasks
        .where((task) => task.status == VideoDownloadStatus.completed)
        .length;
    final size = _sizeLoading
        ? s.calculating
        : _completedBytes == null
        ? s.fetchFailed
        : formatBytes(_completedBytes!);
    return s.downloadedFilesAndSize(completed, size);
  }

  Future<void> _clearVideoSearchHistory(BuildContext context) async {
    final s = S.of(context);
    await ref.read(unifiedSearchHistoryProvider.notifier).load();
    final count = ref
        .read(unifiedSearchHistoryProvider)
        .entries
        .where((entry) => entry.context.contentType == 'video')
        .length;
    if (!context.mounted) return;
    if (count == 0) {
      await ref.read(videoSearchHistoryProvider.notifier).clear();
      if (!context.mounted) return;
      SnackBarUtil.showSuccess(context, s.searchHistoryCleared);
      return;
    }
    final confirmed = await showSettingsResetConfirmation(
      context: context,
      title: s.clearSearchHistory,
      message: s.clearSearchHistoryConfirm,
      confirmLabel: s.confirm,
    );
    if (!confirmed || !context.mounted) return;
    await ref
        .read(unifiedSearchHistoryProvider.notifier)
        .clearContentType('video');
    await ref.read(videoSearchHistoryProvider.notifier).clear();
    if (context.mounted) {
      SnackBarUtil.showSuccess(context, s.searchHistoryCleared);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final downloads = ref.read(videoDownloadsProvider);
    final missav = ref.watch(videoClientProvider);
    final jableAccount = ref.read(jableVideoClientProvider).account;
    final history = ref.watch(unifiedSearchHistoryProvider);
    final historyCount = history.entries
        .where((entry) => entry.context.contentType == 'video')
        .length;

    return SettingsSubpageScaffold(
      title: s.videoSettings,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(s.playback, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SettingsSectionList(
            children: [
              SettingsNavigationTile(
                icon: Icons.play_circle_outline,
                title: s.videoPlayerSettings,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const VideoPlaybackSettingsRoute(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            s.videoInterface,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SettingsSectionList(
            children: [
              SettingsNavigationTile(
                icon: Icons.dashboard_customize,
                title: s.uiSettings,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const VideoUiSettingsScreen(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            s.videoAccountAndSources,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SettingsSectionList(
            children: [
              SettingsNavigationTile(
                icon: Icons.account_circle_outlined,
                title: s.videoSourceAccount,
                subtitle: missav.isLoggedIn
                    ? missav.accountName ?? s.videoAccountSignedIn
                    : s.videoAccountSignedOut,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const VideoAccountScreen(),
                  ),
                ),
              ),
              ListenableBuilder(
                listenable: jableAccount,
                builder: (context, _) => SettingsNavigationTile(
                  icon: Icons.account_circle_outlined,
                  title: s.videoJableAccount,
                  subtitle: jableAccount.isLoggedIn
                      ? s.videoAccountSignedIn
                      : s.videoAccountSignedOut,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const JableAccountScreen(),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            s.downloadsAndStorage,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SettingsSectionList(
            children: [
              ListenableBuilder(
                listenable: downloads,
                builder: (context, _) => SettingsNavigationTile(
                  icon: Icons.download_outlined,
                  title: s.videoDownloads,
                  subtitle: _downloadsSubtitle(s, downloads),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const VideoDownloadsScreen(),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(s.searchHistory, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SettingsSectionList(
            children: [
              SettingsNavigationTile(
                icon: Icons.history,
                title: s.clearSearchHistory,
                subtitle: history.isLoading
                    ? s.calculating
                    : s.nItems(historyCount),
                onTap: () => _clearVideoSearchHistory(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class VideoUiSettingsScreen extends ConsumerWidget {
  const VideoUiSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final layout = ref.watch(videoBrowseLayoutProvider);
    return SettingsSubpageScaffold(
      title: s.uiSettings,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SettingsSectionList(
            children: [
              SettingsNavigationTile(
                icon: Icons.grid_view,
                title: s.layout,
                subtitle: _layoutLabel(s, layout),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (dialogContext) => CommonOptionDialog<LayoutType>(
                    title: S.of(dialogContext).layout,
                    icon: Icons.grid_view,
                    value: layout,
                    options: [
                      for (final value in LayoutType.values)
                        RadioOption(
                          value: value,
                          title: Text(_layoutLabel(S.of(dialogContext), value)),
                        ),
                    ],
                    onChanged: (value) async {
                      await ref
                          .read(videoBrowseLayoutProvider.notifier)
                          .setLayout(value);
                      return true;
                    },
                  ),
                ),
              ),
              SettingsNavigationTile(
                icon: Icons.dashboard_customize,
                title: s.workCardDisplaySettings,
                subtitle: s.workCardDisplaySubtitle,
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
}

String _layoutLabel(S s, LayoutType layout) => switch (layout) {
  LayoutType.bigGrid => s.layoutBigGrid,
  LayoutType.smallGrid => s.layoutSmallGrid,
  LayoutType.list => s.layoutList,
};

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
