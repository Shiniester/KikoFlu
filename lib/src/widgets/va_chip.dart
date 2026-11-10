import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/audio_source.dart';
import '../models/work.dart';
import 'metadata_search_chip.dart';

class VaChip extends StatelessWidget {
  final Va va;
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

  const VaChip({
    super.key,
    required this.va,
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
    return MetadataSearchChip(
      label: va.name,
      searchKeyword: va.name,
      searchTypeLabel: S.of(context).searchTypeVa,
      searchParams: source == AudioSource.jpAsmr
          ? const {}
          : {'vaId': va.id, 'vaName': va.name},
      chipTone: MetadataChipTone.tertiary,
      onDeleted: onDeleted,
      onTap: onTap,
      onLongPress: onLongPress,
      searchEnabled: searchEnabled,
      compact: compact,
      fontSize: fontSize,
      padding: padding,
      borderRadius: borderRadius,
      fontWeight: fontWeight,
      logName: 'VA',
      logId: va.id,
      source: source,
    );
  }
}
