import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../providers/my_tabs_display_provider.dart';
import '../providers/auth_provider.dart';
import '../utils/server_utils.dart';
import '../widgets/settings_section.dart';

class MyTabsDisplaySettingsScreen extends ConsumerWidget {
  const MyTabsDisplaySettingsScreen({super.key});

  Future<void> _resetToDefault(BuildContext context, WidgetRef ref) async {
    await confirmAndRestoreSettingsDefaults(
      context: context,
      restore: ref.read(myTabsDisplayProvider.notifier).resetToDefault,
    );
  }

  String _title(BuildContext context, String page) {
    final s = S.of(context);
    return switch (page) {
      'popular' => s.displayModePopular,
      'recommended' => s.displayModeRecommended,
      'onlineMarks' => s.libraryMarks,
      'history' => s.libraryHistory,
      'playlists' => s.libraryFavorites,
      'downloads' => s.libraryDownloads,
      'subtitleLibrary' => s.librarySubtitles,
      _ => page,
    };
  }

  IconData _icon(String page) => switch (page) {
    'popular' => Icons.local_fire_department,
    'recommended' => Icons.auto_awesome,
    'onlineMarks' => Icons.bookmark,
    'history' => Icons.history,
    'playlists' => Icons.favorite,
    'downloads' => Icons.download_done,
    'subtitleLibrary' => Icons.subtitles,
    _ => Icons.library_music_outlined,
  };

  bool? _visibility(MyTabsDisplaySettings settings, String page) =>
      switch (page) {
        'onlineMarks' => settings.showOnlineMarks,
        'playlists' => settings.showPlaylists,
        'subtitleLibrary' => settings.showSubtitleLibrary,
        _ => null,
      };

  void _setVisibility(
    MyTabsDisplaySettingsNotifier notifier,
    String page,
    bool value,
  ) {
    switch (page) {
      case 'onlineMarks':
        notifier.setShowOnlineMarks(value);
        break;
      case 'playlists':
        notifier.setShowPlaylists(value);
        break;
      case 'subtitleLibrary':
        notifier.setShowSubtitleLibrary(value);
        break;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(myTabsDisplayProvider);
    final notifier = ref.read(myTabsDisplayProvider.notifier);
    final authState = ref.watch(authProvider);
    final isOfficialServer = ServerUtils.isOfficialServer(authState.host);

    return SettingsReorderablePage<String>(
      title: S.of(context).libraryPageOrder,
      infoTitle: S.of(context).libraryPageOrder,
      infoDescription: S.of(context).libraryPageOrderDescription,
      items: settings.pageOrder,
      itemKey: (page) => page,
      onOrderChanged: notifier.setPageOrder,
      onRestoreDefaults: () => _resetToDefault(context, ref),
      itemBuilder: (context, page, index) {
        final visibility = _visibility(settings, page);
        final canToggle =
            visibility != null && (page != 'playlists' || isOfficialServer);
        return ListTile(
          leading: Icon(_icon(page)),
          title: Text(_title(context, page)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (canToggle)
                Switch(
                  value: visibility,
                  onChanged: (value) => _setVisibility(notifier, page, value),
                ),
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.drag_handle),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
