import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/audio_source.dart';
import '../models/work.dart';
import '../utils/tag_localizer.dart';
import 'metadata_search_chip.dart';

class TagChip extends StatelessWidget {
  final Tag tag;
  final VoidCallback? onDeleted;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool searchEnabled;
  final bool compact;
  final double? fontSize;
  final EdgeInsetsGeometry? padding;
  final double? borderRadius;
  final FontWeight? fontWeight;
  final AudioSource? source;

  const TagChip({
    super.key,
    required this.tag,
    this.onDeleted,
    this.onTap,
    this.onLongPress,
    this.searchEnabled = true,
    this.compact = false,
    this.fontSize,
    this.padding,
    this.borderRadius,
    this.fontWeight,
    this.source,
  });

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final localizedName = TagLocalizer.localize(
      tag.id,
      tag.name,
      locale,
      names: tag.names,
    );

    return MetadataSearchChip(
      label: localizedName,
      searchKeyword: source == AudioSource.jpAsmr ? tag.name : localizedName,
      searchTypeLabel: S.of(context).searchTypeTag,
      searchParams: source == AudioSource.jpAsmr
          ? const {}
          : {'tagId': tag.id, 'tagName': tag.name},
      chipTone: MetadataChipTone.secondary,
      customTone: MetadataChipTone.primary,
      muted: tag.isUserAdded,
      onDeleted: onDeleted,
      onTap: onTap,
      onLongPress: onLongPress,
      searchEnabled: searchEnabled,
      compact: compact,
      fontSize: fontSize,
      padding: padding,
      borderRadius: borderRadius,
      fontWeight: fontWeight,
      logName: 'tag',
      logId: tag.id,
      source: source,
    );
  }
}
