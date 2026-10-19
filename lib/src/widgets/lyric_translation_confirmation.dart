import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import 'responsive_dialog.dart';

Future<bool> confirmLyricTranslationIfNeeded(
  BuildContext context, {
  bool forGeneration = false,
}) async {
  const key = 'lyric_translation_confirmed_once';
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(key) ?? false) return true;
  if (!context.mounted) return false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => ResponsiveAlertDialog(
      title: Text(S.of(dialogContext).translateLyrics),
      content: Text(
        forGeneration
            ? S.of(dialogContext).subtitleGenerationTranslationConfirm
            : S.of(dialogContext).lyricTranslationConfirmMessage,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(S.of(dialogContext).cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(S.of(dialogContext).confirm),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  await prefs.setBool(key, true);
  return true;
}
