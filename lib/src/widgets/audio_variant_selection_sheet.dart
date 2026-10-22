import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/audio_variant_selection.dart';
import '../services/player_audio_variant_classifier.dart';
import '../utils/file_tree_utils.dart';
import '../utils/string_utils.dart';
import 'responsive_dialog.dart';

Future<List<AudioVariantSelection>?> showAudioVariantSelectionSheet(
  BuildContext context, {
  required List<PlayerAudioVariant> targets,
  required List<PlayerAudioVariant> allVariants,
  required AudioVariantSelectionPurpose purpose,
  AudioFormatPreference preference = const AudioFormatPreference(),
}) {
  return showResponsiveBottomSheet<List<AudioVariantSelection>>(
    context: context,
    maxWidth: 680,
    maxHeight: 720,
    isScrollControlled: true,
    builder: (_) => _AudioVariantSelectionSheet(
      targets: targets,
      allVariants: allVariants,
      purpose: purpose,
      preference: preference,
    ),
  );
}

class _AudioVariantSelectionSheet extends StatefulWidget {
  const _AudioVariantSelectionSheet({
    required this.targets,
    required this.allVariants,
    required this.purpose,
    required this.preference,
  });

  final List<PlayerAudioVariant> targets;
  final List<PlayerAudioVariant> allVariants;
  final AudioVariantSelectionPurpose purpose;
  final AudioFormatPreference preference;

  @override
  State<_AudioVariantSelectionSheet> createState() =>
      _AudioVariantSelectionSheetState();
}

class _AudioVariantSelectionSheetState
    extends State<_AudioVariantSelectionSheet> {
  late final List<PlayerAudioVariant?> _selected = [
    for (final target in widget.targets)
      AudioVariantSelectionService.recommendFor(
        target: target,
        allVariants: widget.allVariants,
        purpose: widget.purpose,
        preference: widget.preference,
      ),
  ];
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final strings = S.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.9;
    final hint = switch (widget.purpose) {
      AudioVariantSelectionPurpose.subtitleGeneration =>
        strings.audioVariantGenerationHint,
      AudioVariantSelectionPurpose.download => strings.audioVariantDownloadHint,
    };

    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 680, maxHeight: maxHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        strings.audioVariantSelectionTitle,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    hint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const ValueKey('audio-variant-toggle-all'),
                    onPressed: () => setState(() => _showAll = !_showAll),
                    icon: Icon(_showAll ? Icons.filter_alt : Icons.list_alt),
                    label: Text(
                      _showAll
                          ? strings.audioVariantShowSimilar
                          : strings.audioVariantShowAll,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    key: const ValueKey('audio-variant-group-list'),
                    itemCount: widget.targets.length,
                    itemBuilder: (context, index) =>
                        _buildGroup(context, index),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          key: const ValueKey('audio-variant-selection-cancel'),
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(strings.cancel),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          key: const ValueKey(
                            'audio-variant-selection-confirm',
                          ),
                          onPressed: () => Navigator.of(context).pop(_result()),
                          child: Text(strings.confirm),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGroup(BuildContext context, int index) {
    final target = widget.targets[index];
    final selected = _selected[index];
    final strings = S.of(context);
    final candidates = AudioVariantSelectionService.candidatesFor(
      target: target,
      allVariants: widget.allVariants,
      purpose: widget.purpose,
      preference: widget.preference,
      showAll: _showAll,
    );

    return RadioGroup<PlayerAudioVariant>(
      groupValue: selected,
      onChanged: (value) => setState(() => _selected[index] = value),
      child: Card(
        key: ValueKey('audio-variant-group-${target.fullPath}'),
        margin: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      target.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton(
                    key: ValueKey('audio-variant-skip-${target.fullPath}'),
                    onPressed: () => setState(() => _selected[index] = null),
                    child: Text(strings.audioVariantSkip),
                  ),
                ],
              ),
              _pathText(
                '${strings.audioVariantOriginal}: ${target.fullPath}',
                target.fullPath,
              ),
              if (selected == null)
                Text(strings.audioVariantSkip)
              else ...[
                Text(
                  selected.title,
                  key: ValueKey('audio-variant-selected-${target.fullPath}'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                _pathText(selected.fullPath, selected.fullPath),
                Text(_variantSummary(context, selected)),
              ],
              for (final candidate in candidates)
                RadioListTile<PlayerAudioVariant>(
                  key: ValueKey(
                    'audio-variant-option-${target.fullPath}-${candidate.fullPath}',
                  ),
                  value: candidate,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(
                    candidate.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_variantSummary(context, candidate)),
                      _pathText(candidate.fullPath, candidate.fullPath),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pathText(String label, String path) => Tooltip(
    message: path,
    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
  );

  String _variantSummary(BuildContext context, PlayerAudioVariant variant) {
    final strings = S.of(context);
    final size = FileTreeUtils.property(variant.source, 'size');
    final formattedSize = size is num && size > 0
        ? formatBytes(size.toInt())
        : '';
    final format = variant.format == AudioFormat.other
        ? strings.audioFormatOther
        : variant.format.displayName;

    return [
      '${strings.audioFormatLabel}: $format',
      if (formattedSize.isNotEmpty) formattedSize,
      '${strings.audioSoundEffects}: ${_traitLabel(strings, variant.se)}',
      '${strings.audioEjaculationSound}: ${_traitLabel(strings, variant.ejaculation)}',
    ].join(' · ');
  }

  String _traitLabel(S strings, PlayerBinaryTrait trait) => switch (trait) {
    PlayerBinaryTrait.present => strings.audioPresent,
    PlayerBinaryTrait.absent => strings.audioAbsent,
    PlayerBinaryTrait.unknown => strings.unknown,
  };

  List<AudioVariantSelection> _result() {
    final result = <AudioVariantSelection>[];
    for (var index = 0; index < widget.targets.length; index++) {
      final selected = _selected[index];
      if (selected != null) {
        result.add(
          AudioVariantSelection(
            target: widget.targets[index],
            selected: selected,
          ),
        );
      }
    }
    return List.unmodifiable(result);
  }
}
