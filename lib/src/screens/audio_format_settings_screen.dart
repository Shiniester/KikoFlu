import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../providers/settings_provider.dart';
import '../widgets/radio_option_group.dart';
import '../widgets/settings_option_dialog.dart';
import '../widgets/settings_section.dart';

class AudioFormatSettingsScreen extends ConsumerWidget {
  const AudioFormatSettingsScreen({super.key});

  Future<void> _resetToDefault(BuildContext context, WidgetRef ref) async {
    await confirmAndRestoreSettingsDefaults(
      context: context,
      message: S.of(context).confirmRestoreAudioFormat,
      restore: ref.read(audioFormatPreferenceProvider.notifier).resetToDefault,
    );
  }

  void _showSubtitleLanguageDialog(BuildContext context, WidgetRef ref) {
    final preference = ref.read(audioFormatPreferenceProvider);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => CommonOptionDialog<PlayerSubtitleLanguage>(
        title: S.of(dialogContext).audioSubtitleLanguage,
        value: preference.subtitleLanguage,
        options: [
          for (final language in const [
            PlayerSubtitleLanguage.simplifiedChinese,
            PlayerSubtitleLanguage.traditionalChinese,
            PlayerSubtitleLanguage.other,
            PlayerSubtitleLanguage.none,
          ])
            RadioOption(
              value: language,
              title: Text(_subtitleLanguageLabel(dialogContext, language)),
            ),
        ],
        onChanged: (value) async {
          await ref
              .read(audioFormatPreferenceProvider.notifier)
              .updatePreference(preference.copyWith(subtitleLanguage: value));
          return true;
        },
      ),
    );
  }

  void _showTraitDialog(
    BuildContext context,
    WidgetRef ref, {
    required bool ejaculation,
  }) {
    final preference = ref.read(audioFormatPreferenceProvider);
    final currentValue = ejaculation ? preference.ejaculation : preference.se;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => CommonOptionDialog<PlayerBinaryTrait>(
        title: ejaculation
            ? S.of(dialogContext).audioEjaculationSound
            : S.of(dialogContext).audioSoundEffects,
        value: currentValue,
        options: [
          RadioOption(
            value: PlayerBinaryTrait.present,
            title: Text(S.of(dialogContext).audioPresent),
          ),
          RadioOption(
            value: PlayerBinaryTrait.absent,
            title: Text(S.of(dialogContext).audioAbsent),
          ),
        ],
        onChanged: (value) async {
          await ref
              .read(audioFormatPreferenceProvider.notifier)
              .updatePreference(
                ejaculation
                    ? preference.copyWith(ejaculation: value)
                    : preference.copyWith(se: value),
              );
          return true;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preference = ref.watch(audioFormatPreferenceProvider);
    final formats = preference.priority;
    final strings = S.of(context);

    return SettingsSubpageScaffold(
      title: strings.audioFormatPreference,
      onRestoreDefaults: () => _resetToDefault(context, ref),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SettingsSectionList(
            children: [
              SettingsNavigationTile(
                icon: Icons.closed_caption_outlined,
                title: strings.audioSubtitleLanguage,
                subtitle: strings.currentSettingLabel(
                  _subtitleLanguageLabel(context, preference.subtitleLanguage),
                ),
                onTap: () => _showSubtitleLanguageDialog(context, ref),
              ),
              SettingsNavigationTile(
                icon: Icons.surround_sound,
                title: strings.audioSoundEffects,
                subtitle: strings.currentSettingLabel(
                  _traitLabel(context, preference.se),
                ),
                onTap: () => _showTraitDialog(context, ref, ejaculation: false),
              ),
              SettingsNavigationTile(
                icon: Icons.graphic_eq,
                title: strings.audioEjaculationSound,
                subtitle: strings.currentSettingLabel(
                  _traitLabel(context, preference.ejaculation),
                ),
                onTap: () => _showTraitDialog(context, ref, ejaculation: true),
              ),
              SettingsSwitchTile(
                icon: Icons.help_outline,
                title: strings.audioIncludeUnknown,
                subtitle: strings.audioIncludeUnknownDescription,
                value: preference.includeUnknown,
                onChanged: (value) => ref
                    .read(audioFormatPreferenceProvider.notifier)
                    .updatePreference(
                      preference.copyWith(includeUnknown: value),
                    ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SettingsInfoCard(
            icon: Icons.info_outline,
            title: strings.audioFormatPriority,
            margin: const EdgeInsets.only(bottom: 12),
            child: Text(strings.audioFormatPriorityDesc),
          ),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: formats.length,
            onReorderItem: (oldIndex, newIndex) {
              final reordered = List<AudioFormat>.of(formats);
              final format = reordered.removeAt(oldIndex);
              reordered.insert(newIndex, format);
              ref
                  .read(audioFormatPreferenceProvider.notifier)
                  .updatePriority(reordered);
            },
            itemBuilder: (context, index) {
              final format = formats[index];
              return SettingsSectionCard(
                key: ValueKey(format),
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                  title: Text(
                    _formatLabel(context, format),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  subtitle: Text(
                    '.${format.extension}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: ReorderableDragStartListener(
                    index: index,
                    child: Icon(
                      Icons.drag_handle,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

String _subtitleLanguageLabel(
  BuildContext context,
  PlayerSubtitleLanguage language,
) {
  final strings = S.of(context);
  return switch (language) {
    PlayerSubtitleLanguage.simplifiedChinese =>
      strings.audioSubtitleSimplifiedChinese,
    PlayerSubtitleLanguage.traditionalChinese =>
      strings.audioSubtitleTraditionalChinese,
    PlayerSubtitleLanguage.other => strings.audioSubtitleOtherLanguage,
    PlayerSubtitleLanguage.none => strings.audioSubtitleNone,
    PlayerSubtitleLanguage.unknown => strings.unknown,
  };
}

String _traitLabel(BuildContext context, PlayerBinaryTrait trait) {
  final strings = S.of(context);
  return switch (trait) {
    PlayerBinaryTrait.present => strings.audioPresent,
    PlayerBinaryTrait.absent => strings.audioAbsent,
    PlayerBinaryTrait.unknown => strings.unknown,
  };
}

String _formatLabel(BuildContext context, AudioFormat format) =>
    format == AudioFormat.other
    ? S.of(context).audioFormatOther
    : format.displayName;
