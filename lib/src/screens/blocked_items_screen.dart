import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../models/audio_source.dart';
import '../models/search_type.dart';
import '../providers/settings_provider.dart';
import '../utils/snackbar_util.dart';
import '../utils/tag_localizer.dart';
import '../utils/ui_tokens.dart';
import '../providers/auth_provider.dart';
import '../widgets/japanese_asmr_access_prompt.dart';

class BlockedItemsScreen extends ConsumerWidget {
  const BlockedItemsScreen({super.key, required this.source});

  final AudioSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(S.of(context).blockedItems, style: UiTextStyles.pageTitle),
              Text(source.label, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
          bottom: TabBar(
            tabs: [
              Tab(text: S.of(context).searchTypeTag),
              Tab(text: S.of(context).searchTypeVa),
              Tab(text: S.of(context).searchTypeCircle),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _BlockedList(type: _BlockedType.tag, source: source),
            _BlockedList(type: _BlockedType.cv, source: source),
            _BlockedList(type: _BlockedType.circle, source: source),
          ],
        ),
      ),
    );
  }
}

enum _BlockedType { tag, cv, circle }

class _BlockedList extends ConsumerWidget {
  final _BlockedType type;
  final AudioSource source;

  const _BlockedList({required this.type, required this.source});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blockedItems = ref.watch(blockedItemsBySourceProvider(source));
    final List<String> items;
    final String label;

    switch (type) {
      case _BlockedType.tag:
        items = blockedItems.tags;
        label = S.of(context).searchTypeTag;
        break;
      case _BlockedType.cv:
        items = blockedItems.cvs;
        label = S.of(context).searchTypeVa;
        break;
      case _BlockedType.circle:
        items = blockedItems.circles;
        label = S.of(context).searchTypeCircle;
        break;
    }

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => showDialog(
          context: context,
          builder: (context) =>
              _AddItemDialog(type: type, label: label, source: source),
        ),
        child: const Icon(Icons.add),
      ),
      body: items.isEmpty
          ? Center(
              child: Text(
                S.of(context).noBlockedItemsOfType(label),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final displayItem =
                    source == AudioSource.asmrOne && type == _BlockedType.tag
                    ? TagLocalizer.localizeByName(
                        item,
                        Localizations.localeOf(context),
                      )
                    : item;
                return ListTile(
                  title: Text(displayItem),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () {
                      _removeItem(ref, type, item);
                      SnackBarUtil.showSuccess(
                        context,
                        S.of(context).unblockedItem(item),
                      );
                    },
                  ),
                );
              },
            ),
    );
  }

  void _removeItem(WidgetRef ref, _BlockedType type, String item) {
    final notifier = ref.read(blockedItemsBySourceProvider(source).notifier);
    switch (type) {
      case _BlockedType.tag:
        notifier.removeTag(item);
        break;
      case _BlockedType.cv:
        notifier.removeCv(item);
        break;
      case _BlockedType.circle:
        notifier.removeCircle(item);
        break;
    }
  }
}

class _AddItemDialog extends ConsumerStatefulWidget {
  final _BlockedType type;
  final String label;
  final AudioSource source;

  const _AddItemDialog({
    required this.type,
    required this.label,
    required this.source,
  });

  @override
  ConsumerState<_AddItemDialog> createState() => _AddItemDialogState();
}

class _AddItemDialogState extends ConsumerState<_AddItemDialog> {
  final _controller = TextEditingController();
  List<Map<String, dynamic>> _suggestions = [];
  bool _isLoading = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadSuggestions();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadSuggestions() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final api = ref.read(kikoeruApiServiceProvider);
      List<dynamic> data = [];

      if (widget.source == AudioSource.jpAsmr) {
        data = await api.getSearchCatalog(switch (widget.type) {
          _BlockedType.tag => SearchType.tag,
          _BlockedType.cv => SearchType.va,
          _BlockedType.circle => SearchType.circle,
        });
      } else {
        switch (widget.type) {
          case _BlockedType.tag:
            data = await api.getAllTags();
            break;
          case _BlockedType.cv:
            data = await api.getAllVas();
            break;
          case _BlockedType.circle:
            data = await api.getAllCircles();
            break;
        }
      }

      if (mounted) {
        setState(() {
          _suggestions = List<Map<String, dynamic>>.from(data);
          // 按 count 字段从大到小排序
          _suggestions.sort(
            (a, b) => (b['count'] ?? 0).compareTo(a['count'] ?? 0),
          );
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadError = e.toString();
        });
      }
    }
  }

  void _addItem(String item) {
    final notifier = ref.read(
      blockedItemsBySourceProvider(widget.source).notifier,
    );
    switch (widget.type) {
      case _BlockedType.tag:
        notifier.addTag(item);
        break;
      case _BlockedType.cv:
        notifier.addCv(item);
        break;
      case _BlockedType.circle:
        notifier.addCircle(item);
        break;
    }
    Navigator.pop(context);
    SnackBarUtil.showSuccess(context, S.of(context).blockedItemAdded(item));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(S.of(context).addBlockedItem(widget.label)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isLoading)
              const LinearProgressIndicator()
            else if (_loadError?.contains('[jp-asmr-verification-required]') ==
                true)
              JapaneseAsmrAccessPrompt(
                onRetry: _loadSuggestions,
                onVerified: _loadSuggestions,
              )
            else
              Autocomplete<Map<String, dynamic>>(
                initialValue: TextEditingValue(text: _controller.text),
                optionsBuilder: (TextEditingValue textEditingValue) {
                  List<Map<String, dynamic>> filteredList;
                  if (textEditingValue.text.trim().isEmpty) {
                    filteredList = _suggestions.toList();
                  } else {
                    final query = textEditingValue.text.trim().toLowerCase();
                    filteredList = _suggestions.where((option) {
                      final name = option['name'].toString().toLowerCase();
                      if (name.contains(query)) return true;
                      if (widget.source == AudioSource.asmrOne &&
                          widget.type == _BlockedType.tag &&
                          option['id'] != null) {
                        final localizedName = TagLocalizer.localize(
                          option['id'] as int,
                          option['name'] as String,
                          Localizations.localeOf(context),
                        ).toLowerCase();
                        if (localizedName.contains(query)) return true;
                      }
                      return false;
                    }).toList();
                  }
                  return filteredList;
                },
                displayStringForOption: (Map<String, dynamic> option) {
                  if (widget.source == AudioSource.asmrOne &&
                      widget.type == _BlockedType.tag &&
                      option['id'] != null) {
                    return TagLocalizer.localize(
                      option['id'] as int,
                      option['name'],
                      Localizations.localeOf(context),
                    );
                  }
                  return option['name'];
                },
                fieldViewBuilder:
                    (
                      context,
                      textEditingController,
                      focusNode,
                      onFieldSubmitted,
                    ) {
                      // 同步控制器，以便在点击"添加"按钮时获取文本
                      textEditingController.addListener(() {
                        _controller.text = textEditingController.text;
                      });
                      return TextField(
                        controller: textEditingController,
                        focusNode: focusNode,
                        decoration: InputDecoration(
                          labelText: S
                              .of(context)
                              .blockedItemName(widget.label),
                          hintText: S
                              .of(context)
                              .enterBlockedItemHint(widget.label),
                          suffixIcon: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : null,
                        ),
                        autofocus: true,
                        onSubmitted: (value) {
                          if (value.trim().isNotEmpty) {
                            _addItem(value.trim());
                          }
                        },
                      );
                    },
                optionsViewBuilder: (context, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 4.0,
                      child: SizedBox(
                        width: 300, // 限制宽度
                        height: 300, // 限制高度
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          itemCount: options.length,
                          itemBuilder: (BuildContext context, int index) {
                            final Map<String, dynamic> option = options
                                .elementAt(index);
                            final displayName =
                                (widget.source == AudioSource.asmrOne &&
                                    widget.type == _BlockedType.tag &&
                                    option['id'] != null)
                                ? TagLocalizer.localize(
                                    option['id'] as int,
                                    option['name'],
                                    Localizations.localeOf(context),
                                  )
                                : option['name'] as String;
                            return ListTile(
                              title: Text(displayName),
                              subtitle: option['count'] != null
                                  ? Text(
                                      S
                                          .of(context)
                                          .workCountLabel(
                                            option['count'] as int,
                                          ),
                                    )
                                  : null,
                              onTap: () {
                                onSelected(option);
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
                onSelected: (Map<String, dynamic> selection) {
                  _controller.text = selection['name'];
                  // 选中后不自动提交，让用户确认
                },
              ),
            if (_loadError != null &&
                !_loadError!.contains('[jp-asmr-verification-required]'))
              Row(
                children: [
                  Expanded(child: Text(S.of(context).loadFailed)),
                  IconButton(
                    tooltip: S.of(context).retry,
                    onPressed: _loadSuggestions,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(S.of(context).cancel),
        ),
        TextButton(
          onPressed: () {
            final text = _controller.text.trim();
            if (text.isNotEmpty) {
              _addItem(text);
            }
          },
          child: Text(S.of(context).add),
        ),
      ],
    );
  }
}
