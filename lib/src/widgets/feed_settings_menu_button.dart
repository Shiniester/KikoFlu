import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

enum FeedSettingsAction { layout, subtitles, sort }

class FeedSettingsMenuButton extends StatelessWidget {
  const FeedSettingsMenuButton({
    super.key,
    required this.onSelected,
    this.sortEnabled = true,
  });

  final ValueChanged<FeedSettingsAction> onSelected;
  final bool sortEnabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: PopupMenuButton<FeedSettingsAction>(
        tooltip: S.of(context).feedSettings,
        padding: EdgeInsets.zero,
        onSelected: onSelected,
        itemBuilder: (context) => [
          PopupMenuItem(
            value: FeedSettingsAction.layout,
            child: Text(S.of(context).layout),
          ),
          PopupMenuItem(
            value: FeedSettingsAction.subtitles,
            child: Text(S.of(context).subtitleBadge),
          ),
          PopupMenuItem(
            value: FeedSettingsAction.sort,
            enabled: sortEnabled,
            child: Text(S.of(context).sort),
          ),
        ],
        child: const SizedBox(
          width: 40,
          height: 40,
          child: Icon(Icons.more_vert, size: 20),
        ),
      ),
    );
  }
}
