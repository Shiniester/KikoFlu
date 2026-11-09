import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/audio_track.dart';
import '../../providers/player_buttons_provider.dart';
import '../../providers/settings_provider.dart';
import '../responsive_dialog.dart';
import 'player_action_menu_item.dart';

class PlayerInfoPanel extends ConsumerWidget {
  const PlayerInfoPanel({
    super.key,
    required this.track,
    required this.currentProgress,
    required this.onMarkPressed,
    required this.onDetailPressed,
    required this.onQueuePressed,
    required this.onImmersiveLyrics,
    required this.onLyricSettings,
    this.visibleActionCount = 5,
  });

  final AudioTrack track;
  final String? currentProgress;
  final VoidCallback? onMarkPressed;
  final VoidCallback? onDetailPressed;
  final VoidCallback onQueuePressed;
  final VoidCallback onImmersiveLyrics;
  final VoidCallback onLyricSettings;
  final int visibleActionCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = !Platform.isAndroid && !Platform.isIOS;
    final config = isDesktop
        ? ref.watch(playerButtonsConfigDesktopProvider)
        : ref.watch(playerButtonsConfigMobileProvider);
    final overflow = config
        .getMoreButtons(slotCount: visibleActionCount)
        .where((action) => action != PlayerButtonType.detail)
        .toList(growable: false);
    final keepAwake = ref.watch(keepScreenAwakeProvider);

    return RepaintBoundary(
      child: BottomSheetMenu(
        key: const PageStorageKey('player-info-panel'),
        header: BottomSheetHeader(
          title: MaterialLocalizations.of(context).moreButtonTooltip,
        ),
        children: [
          SwitchListTile(
            key: const ValueKey('player-more-keep-awake-card'),
            secondary: Icon(
              keepAwake ? Icons.light_mode : Icons.light_mode_outlined,
            ),
            title: Text(S.of(context).keepScreenAwake),
            value: keepAwake,
            onChanged: (value) =>
                ref.read(keepScreenAwakeProvider.notifier).setEnabled(value),
          ),
          ListTile(
            key: const ValueKey('player-more-fullscreen-card'),
            leading: const Icon(Icons.fullscreen),
            title: Text(S.of(context).fullscreenLyrics),
            onTap: onImmersiveLyrics,
          ),
          for (final action in overflow)
            PlayerActionMenuItem(
              action: action,
              mode: PlayerActionMenuMode.infoPanel,
              actionContext: context,
              currentProgress: currentProgress,
              onMarkPressed: onMarkPressed,
              onDetailPressed: onDetailPressed,
              onQueuePressed: onQueuePressed,
            ),
          ListTile(
            key: const ValueKey('player-more-lyric-settings-card'),
            leading: const Icon(Icons.text_fields),
            title: Text(S.of(context).playerLyricViewSettings),
            onTap: onLyricSettings,
          ),
          ListTile(
            key: const ValueKey('player-more-action-detail'),
            leading: const Icon(Icons.info_outline),
            title: Text(S.of(context).viewDetail),
            enabled: onDetailPressed != null,
            onTap: onDetailPressed,
          ),
        ],
      ),
    );
  }
}
