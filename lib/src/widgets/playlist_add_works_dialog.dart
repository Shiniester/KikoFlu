import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/work_id_parser.dart';
import 'responsive_dialog.dart';

class PlaylistAddWorksDialog extends StatefulWidget {
  const PlaylistAddWorksDialog({
    super.key,
    required this.onAddWorks,
  });

  static Future<void> show({
    required BuildContext context,
    required ValueChanged<List<String>> onAddWorks,
  }) {
    return showResponsiveBottomSheet<void>(
      context: context,
      builder: (context) => PlaylistAddWorksDialog(onAddWorks: onAddWorks),
    );
  }

  final ValueChanged<List<String>> onAddWorks;

  @override
  State<PlaylistAddWorksDialog> createState() => _PlaylistAddWorksDialogState();
}

class _PlaylistAddWorksDialogState extends State<PlaylistAddWorksDialog> {
  final TextEditingController _textController = TextEditingController();
  // Keep input focus when moving between the two scroll layouts.
  final _formKey = GlobalKey();
  List<String> _parsedWorkIds = [];

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    return LayoutBuilder(
      builder: (context, _) {
        // Ancestors may consume MediaQuery.viewInsets before this content is laid out.
        final scrollWholeSheet =
            isLandscape && View.of(context).viewInsets.bottom > 0;
        final form = Padding(
          key: _formKey,
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                S.of(context).addWorksInputHint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _textController,
                decoration: InputDecoration(
                  labelText: S.of(context).workId,
                  hintText: S.of(context).workIdHint,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.music_note),
                ),
                maxLines: 5,
                autofocus: true,
                onChanged: _handleInputChanged,
              ),
              if (_parsedWorkIds.isNotEmpty) ...[
                const SizedBox(height: 16),
                _ParsedWorkIdsPreview(ids: _parsedWorkIds),
              ],
            ],
          ),
        );

        final sheet = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BottomSheetHeader(
              title: S.of(context).addWorks,
              showCloseButton: isLandscape,
            ),
            const Divider(height: 1),
            if (scrollWholeSheet)
              form
            else
              Flexible(child: SingleChildScrollView(child: form)),
            BottomSheetActionBar(
              secondaryLabel: S.of(context).cancel,
              onSecondaryPressed: () => Navigator.of(context).pop(),
              primaryLabel: _parsedWorkIds.isEmpty
                  ? S.of(context).add
                  : S.of(context).addNWorks(_parsedWorkIds.length),
              onPrimaryPressed: _parsedWorkIds.isEmpty
                  ? null
                  : _submitParsedIds,
            ),
          ],
        );
        return scrollWholeSheet ? SingleChildScrollView(child: sheet) : sheet;
      },
    );
  }

  void _handleInputChanged(String text) {
    setState(() {
      _parsedWorkIds = WorkIdParser.extractRJIds(text);
    });
  }

  void _submitParsedIds() {
    final ids = List<String>.unmodifiable(_parsedWorkIds);
    Navigator.of(context).pop();
    widget.onAddWorks(ids);
  }
}

class _ParsedWorkIdsPreview extends StatelessWidget {
  const _ParsedWorkIdsPreview({required this.ids});

  final List<String> ids;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .primaryContainer
            .withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.check_circle_outline,
                size: 16,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  S.of(context).detectedNWorkIds(ids.length),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ids.map((id) {
              return Chip(
                label: Text(
                  id,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                visualDensity: VisualDensity.compact,
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
