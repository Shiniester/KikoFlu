import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/cache_service.dart';
import '../services/generated_subtitle_store.dart';
import '../services/log_service.dart';
import '../services/translation_service.dart';
import '../services/subtitle_library_service.dart';
import '../services/storage_service.dart';
import '../services/remote_asset_cache.dart';
import '../services/remote_text_loader.dart';
import '../providers/settings_provider.dart';
import '../providers/lyric_provider.dart';
import '../providers/subtitle_search_query_provider.dart';
import '../utils/snackbar_util.dart';
import '../utils/encoding_utils.dart';
import '../utils/file_icon_utils.dart';
import '../utils/local_file_url.dart';
import '../utils/scroll_optimization.dart';
import '../../l10n/app_localizations.dart';
import 'scrollable_appbar.dart';
import 'translation_toggle_button.dart';
import 'responsive_dialog.dart';

/// 文本预览屏幕
class TextPreviewScreen extends ConsumerStatefulWidget {
  final String textUrl;
  final String title;
  final int? workId;
  final String? hash;
  final VoidCallback? onSavedToLibrary;
  final bool showSaveOptionsOnLoad;
  final bool autoTranslate;
  @visibleForTesting
  final Future<String> Function(String source)? translateContentForTesting;

  const TextPreviewScreen({
    super.key,
    required this.textUrl,
    required this.title,
    this.workId,
    this.hash,
    this.onSavedToLibrary,
    this.showSaveOptionsOnLoad = false,
    this.autoTranslate = false,
    this.translateContentForTesting,
  });

  @override
  ConsumerState<TextPreviewScreen> createState() => _TextPreviewScreenState();
}

class _TextPreviewScreenState extends ConsumerState<TextPreviewScreen> {
  static const TextStyle _contentTextStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 14,
  );

  bool _isLoading = true;
  String? _content;
  String? _translatedContent;
  String? _translationTargetKey;
  String? _errorMessage;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _scrollViewportKey = GlobalKey();
  final GlobalKey _previewContentKey = GlobalKey();
  final GlobalKey _editContentKey = GlobalKey();
  final ScrollThrottler _scrollThrottler = ScrollThrottler();
  double _scrollProgress = 0.0;
  bool _showTranslation = false;
  bool _isTranslating = false;
  String _translationProgress = '';
  bool _isEditMode = false;
  bool _isSearchMode = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _editFocusNode = FocusNode();
  List<_TextSearchMatch> _searchMatches = const [];
  List<_TextSearchMarker> _searchMarkers = const [];
  int _currentSearchMatchIndex = -1;
  bool _searchMarkerLayoutScheduled = false;
  Size? _lastSearchViewportSize;
  TextScaler? _lastTextScaler;
  TextDirection? _lastTextDirection;
  Locale? _lastTextLocale;
  bool _hasLoadedContent = false;
  bool _initialSaveOptionsShown = false;
  bool _autoTranslationStarted = false;
  int _translationGeneration = 0;
  late TextEditingController _textController;
  late TextEditingController _translatedTextController;
  String _detectedEncoding = 'UTF-8'; // 记录检测到的原始编码
  RemoteTextLease? _remoteTextLease;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController();
    _translatedTextController = TextEditingController();
    _scrollController.addListener(_updateScrollProgress);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_hasLoadedContent) return;

    _hasLoadedContent = true;
    _loadTextContent();
  }

  @override
  void dispose() {
    final remoteTextLease = _remoteTextLease;
    _remoteTextLease = null;
    if (remoteTextLease != null) {
      unawaited(remoteTextLease.release());
    }
    _scrollController.removeListener(_updateScrollProgress);
    _scrollController.dispose();
    _scrollThrottler.dispose();
    _textController.dispose();
    _translatedTextController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _editFocusNode.dispose();
    super.dispose();
  }

  void _updateScrollProgress() {
    _scrollThrottler.throttle(() {
      if (mounted && _scrollController.hasClients) {
        final maxScroll = _scrollController.position.maxScrollExtent;
        final currentScroll = _scrollController.position.pixels;
        setState(() {
          _scrollProgress = maxScroll > 0 ? currentScroll / maxScroll : 0.0;
        });
      }
    });
  }

  /// 智能检测文件编码并读取内容
  /// 支持 UTF-8、GBK、Shift-JIS 等常见编码
  Future<String> _readFileWithEncoding(File file) async {
    try {
      final (content, encoding) = await EncodingUtils.readFileWithEncoding(
        file,
      );
      _detectedEncoding = encoding;
      LogService.instance.debug('检测到文件编码: $encoding', tag: 'TextPreview');
      return content;
    } catch (e) {
      LogService.instance.error('读取文件失败: $e', tag: 'TextPreview');
      rethrow;
    }
  }

  /// 将字符串编码为字节数组
  /// 使用检测到的原始编码，保持文件编码一致性
  List<int> _encodeString(String content) {
    LogService.instance.debug('使用 $_detectedEncoding 编码保存', tag: 'TextPreview');
    return EncodingUtils.encodeString(content, _detectedEncoding);
  }

  void _showSaveOptions() {
    showBottomSheetMenu(
      context: context,
      children: [
        ListTile(
          leading: const Icon(Icons.folder_open),
          title: Text(S.of(context).saveToLocal),
          subtitle: Text(S.of(context).selectDirectoryToSaveFile),
          onTap: () {
            Navigator.pop(context);
            _saveToLocal();
          },
        ),
        ListTile(
          leading: const Icon(Icons.library_books),
          title: Text(S.of(context).saveToSubtitleLibrary),
          subtitle: Text(S.of(context).saveToSubtitleLibraryDesc),
          onTap: () {
            Navigator.pop(context);
            _saveToSubtitleLibrary();
          },
        ),
      ],
    );
  }

  void _showInitialSaveOptionsIfNeeded() {
    if (!widget.showSaveOptionsOnLoad || _initialSaveOptionsShown) return;
    _initialSaveOptionsShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showSaveOptions();
    });
  }

  Future<void> _saveToLocal() async {
    final l10n = S.of(context);
    // 获取当前显示的内容（可能是编辑后的）
    final contentToSave = _getCurrentContent();
    if (contentToSave == null || contentToSave.isEmpty) {
      if (mounted) {
        SnackBarUtil.showWarning(context, l10n.noContentToSave);
      }
      return;
    }

    try {
      // 生成文件名
      String fileName = widget.title;
      if (!fileName.contains('.')) {
        fileName = '$fileName.txt';
      }

      if (Platform.isIOS) {
        // iOS: 通过分享面板保存
        final tempDir = await getTemporaryDirectory();
        final tempFile = File(path.join(tempDir.path, fileName));
        final bytes = _encodeString(contentToSave);
        await tempFile.writeAsBytes(bytes);
        if (!mounted) return;
        try {
          final box = context.findRenderObject() as RenderBox?;
          await Share.shareXFiles(
            [XFile(tempFile.path)],
            sharePositionOrigin: box != null
                ? box.localToGlobal(Offset.zero) & box.size
                : Rect.fromLTWH(0, 0, MediaQuery.sizeOf(context).width, 80),
          );
        } finally {
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        }
      } else {
        // 其他平台: 选择目录后写入
        final directoryPath = await FilePicker.platform.getDirectoryPath();
        if (directoryPath == null) return;

        // 检查文件是否已存在，如果存在则添加序号
        String finalPath = path.join(directoryPath, fileName);
        int counter = 1;
        while (await File(finalPath).exists()) {
          final nameWithoutExt = path.basenameWithoutExtension(fileName);
          final ext = path.extension(fileName);
          finalPath = path.join(
            directoryPath,
            '${nameWithoutExt}_$counter$ext',
          );
          counter++;
        }

        // 写入文件
        final file = File(finalPath);
        final bytes = _encodeString(contentToSave);
        await file.writeAsBytes(bytes);

        if (!mounted) return;
        SnackBarUtil.showSuccess(context, l10n.fileSavedToPath(finalPath));
      }
    } catch (e) {
      if (!mounted) return;
      SnackBarUtil.showError(context, l10n.saveFailedWithError(e.toString()));
    }
  }

  Future<void> _saveToSubtitleLibrary() async {
    final l10n = S.of(context);
    // 获取当前显示的内容（可能是编辑后的）
    final contentToSave = _getCurrentContent();
    if (contentToSave == null || contentToSave.isEmpty) {
      if (mounted) {
        SnackBarUtil.showWarning(context, l10n.noContentToSave);
      }
      return;
    }

    try {
      await _writeSubtitleToLibrary(contentToSave);

      // 触发字幕库重载回调
      if (!mounted) return;
      widget.onSavedToLibrary?.call();

      // 等待下一帧再显示成功提示
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          SnackBarUtil.showSuccess(context, l10n.savedToSubtitleLibrary);
        }
      });
    } catch (e) {
      if (!mounted) return;
      SnackBarUtil.showError(context, l10n.saveFailedWithError(e.toString()));
    }
  }

  Future<void> _writeSubtitleToLibrary(
    String contentToSave, {
    bool Function()? shouldWrite,
  }) async {
    if (shouldWrite != null && !shouldWrite()) return;
    final libraryDir =
        await SubtitleLibraryService.getSubtitleLibraryDirectory();
    if (shouldWrite != null && !shouldWrite()) return;
    final savedDir = Directory(
      path.join(libraryDir.path, SubtitleLibraryService.savedFolderName),
    );
    if (!await savedDir.exists()) {
      await savedDir.create();
    }

    var fileName = widget.title;
    if (!fileName.contains('.')) {
      fileName = '$fileName.txt';
    }

    var finalPath = path.join(savedDir.path, fileName);
    var counter = 1;
    while (await File(finalPath).exists()) {
      final nameWithoutExt = path.basenameWithoutExtension(fileName);
      final ext = path.extension(fileName);
      finalPath = path.join(savedDir.path, '${nameWithoutExt}_$counter$ext');
      counter++;
    }

    if (shouldWrite != null && !shouldWrite()) return;
    final bytes = _encodeString(contentToSave);
    final file = File(finalPath);
    await file.writeAsBytes(bytes);
    if (shouldWrite != null && !shouldWrite()) {
      await file.delete();
      return;
    }
    await SubtitleLibraryService.refreshDirectoryCache(savedDir.path);
  }

  String? _getCurrentContent() {
    if (_showTranslation && _translatedContent != null) {
      return _translatedTextController.text;
    } else {
      return _textController.text;
    }
  }

  void _openSearch() {
    final rememberedQuery = ref.read(subtitleSearchQueryProvider);
    _searchController.value = TextEditingValue(
      text: rememberedQuery,
      selection: TextSelection.collapsed(offset: rememberedQuery.length),
    );
    setState(() {
      _isSearchMode = true;
    });
    _updateSearchResults(_searchController.text);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  void _closeSearch() {
    _searchController.clear();
    setState(() {
      _isSearchMode = false;
      _searchMatches = const [];
      _searchMarkers = const [];
      _currentSearchMatchIndex = -1;
    });
  }

  void _toggleSearch() {
    if (_isSearchMode) {
      _closeSearch();
    } else {
      _openSearch();
    }
  }

  void _clearSearch() {
    _searchController.clear();
    ref.read(subtitleSearchQueryProvider.notifier).setQuery('');
    _updateSearchResults('');
    _searchFocusNode.requestFocus();
  }

  void _handleSearchInput(String query) {
    ref.read(subtitleSearchQueryProvider.notifier).setQuery(query);
    _updateSearchResults(query);
  }

  void _refreshSearchResults() {
    if (!_isSearchMode) return;
    _updateSearchResults(_searchController.text);
  }

  void _updateSearchResults(String query) {
    final content = _getCurrentContent() ?? '';
    final matches = _findTextMatches(content, query);

    setState(() {
      _searchMatches = matches;
      _searchMarkers = const [];
      _currentSearchMatchIndex = matches.isEmpty ? -1 : 0;
    });

    if (matches.isNotEmpty) {
      _scheduleSearchMarkerLayout();
      _scheduleScrollToCurrentMatch();
    }
  }

  void _moveToSearchMatch(int offset) {
    if (_searchMatches.isEmpty) return;

    final nextIndex =
        (_currentSearchMatchIndex + offset) % _searchMatches.length;
    setState(() {
      _currentSearchMatchIndex = nextIndex;
    });
    _scheduleSearchMarkerLayout();
    _scheduleScrollToCurrentMatch();
  }

  void _selectSearchMatch(int index) {
    if (index < 0 || index >= _searchMatches.length) return;

    if (_currentSearchMatchIndex != index) {
      setState(() {
        _currentSearchMatchIndex = index;
      });
      _scheduleSearchMarkerLayout();
    }

    if (_isEditMode) {
      final match = _searchMatches[index];
      final controller = _showTranslation && _translatedContent != null
          ? _translatedTextController
          : _textController;
      controller.selection = TextSelection(
        baseOffset: match.start,
        extentOffset: match.end,
      );
      _editFocusNode.requestFocus();
    }

    _scheduleScrollToCurrentMatch();
  }

  void _selectNearestSearchMarker(double y) {
    if (_searchMarkers.isEmpty || !_scrollController.hasClients) return;

    final viewportHeight = _scrollController.position.viewportDimension;
    if (viewportHeight <= 0) return;

    var nearestMarker = _searchMarkers.first;
    var nearestDistance = (nearestMarker.position * viewportHeight - y).abs();
    for (final marker in _searchMarkers.skip(1)) {
      final distance = (marker.position * viewportHeight - y).abs();
      if (distance < nearestDistance) {
        nearestMarker = marker;
        nearestDistance = distance;
      }
    }

    _selectSearchMatch(nearestMarker.firstMatchIndex);
  }

  void _scheduleSearchMarkerLayout() {
    if (!_isSearchMode ||
        _searchMatches.isEmpty ||
        _searchMarkerLayoutScheduled) {
      return;
    }

    _searchMarkerLayoutScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchMarkerLayoutScheduled = false;
      if (!mounted || !_isSearchMode || _searchMatches.isEmpty) return;

      final position = _scrollController.hasClients
          ? _scrollController.position
          : null;
      if (position == null || position.viewportDimension <= 0) return;

      final renderEditable = _findDescendantRenderObject<RenderEditable>(
        (_isEditMode ? _editContentKey : _previewContentKey).currentContext,
      );
      final viewport = _findDescendantRenderObject<RenderAbstractViewport>(
        _scrollViewportKey.currentContext,
      );
      if (renderEditable == null || viewport == null) return;

      final contentExtent =
          position.maxScrollExtent + position.viewportDimension;
      if (contentExtent <= 0) return;

      final textLength = (_getCurrentContent() ?? '').length;
      final markers = <_TextSearchMarker>[];
      var previousOffset = double.negativeInfinity;
      for (var index = 0; index < _searchMatches.length; index++) {
        final match = _searchMatches[index];
        if (match.start < 0 || match.end > textLength) {
          continue;
        }

        final caretRect = renderEditable.getLocalRectForCaret(
          TextPosition(offset: match.start),
        );
        final revealOffset = viewport
            .getOffsetToReveal(renderEditable, 0, rect: caretRect)
            .offset;
        if (!revealOffset.isFinite) continue;

        final markerPosition = (revealOffset / contentExtent)
            .clamp(0.0, 1.0)
            .toDouble();
        if (markers.isNotEmpty && (revealOffset - previousOffset).abs() < 1) {
          final previousMarker = markers.removeLast();
          markers.add(
            _TextSearchMarker(
              position: previousMarker.position,
              firstMatchIndex: previousMarker.firstMatchIndex,
              lastMatchIndex: index,
            ),
          );
        } else {
          markers.add(
            _TextSearchMarker(
              position: markerPosition,
              firstMatchIndex: index,
              lastMatchIndex: index,
            ),
          );
        }
        previousOffset = revealOffset;
      }

      if (_sameSearchMarkers(_searchMarkers, markers)) return;
      setState(() {
        _searchMarkers = markers;
      });
    });
  }

  T? _findDescendantRenderObject<T extends RenderObject>(
    BuildContext? context,
  ) {
    final root = context?.findRenderObject();
    if (root == null) return null;

    T? result;
    void visit(RenderObject renderObject) {
      if (renderObject is T) {
        result = renderObject;
        return;
      }
      renderObject.visitChildren((child) {
        if (result == null) visit(child);
      });
    }

    visit(root);
    return result;
  }

  bool _sameSearchMarkers(
    List<_TextSearchMarker> first,
    List<_TextSearchMarker> second,
  ) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index].firstMatchIndex != second[index].firstMatchIndex ||
          first[index].lastMatchIndex != second[index].lastMatchIndex ||
          (first[index].position - second[index].position).abs() > 0.0001) {
        return false;
      }
    }
    return true;
  }

  void _scheduleScrollToCurrentMatch() {
    final scheduledIndex = _currentSearchMatchIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || scheduledIndex != _currentSearchMatchIndex) return;
      _scrollToCurrentMatch();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _scrollToCurrentMatch() {
    if (!_scrollController.hasClients ||
        _currentSearchMatchIndex < 0 ||
        _currentSearchMatchIndex >= _searchMatches.length) {
      return;
    }

    final renderEditable = _findDescendantRenderObject<RenderEditable>(
      (_isEditMode ? _editContentKey : _previewContentKey).currentContext,
    );
    final viewport = _findDescendantRenderObject<RenderAbstractViewport>(
      _scrollViewportKey.currentContext,
    );
    if (renderEditable == null || viewport == null) return;

    final match = _searchMatches[_currentSearchMatchIndex];
    final position = _scrollController.position;
    final textLength = (_getCurrentContent() ?? '').length;
    if (match.start < 0 || match.end > textLength) {
      return;
    }
    final caretRect = renderEditable.getLocalRectForCaret(
      TextPosition(offset: match.start),
    );
    final targetOffset = viewport
        .getOffsetToReveal(renderEditable, 0.25, rect: caretRect)
        .offset
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();

    if (MediaQuery.disableAnimationsOf(context)) {
      _scrollController.jumpTo(targetOffset);
      return;
    }
    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _buildSearchBar() {
    final l10n = S.of(context);
    final hasMatches = _searchMatches.isNotEmpty;
    final resultLabel = hasMatches
        ? '${_currentSearchMatchIndex + 1}/${_searchMatches.length}'
        : '0/0';

    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('text-preview-search-field'),
                controller: _searchController,
                focusNode: _searchFocusNode,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: l10n.searchSubtitles,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchController.text.isEmpty
                      ? null
                      : IconButton(
                          key: const ValueKey('text-preview-search-clear'),
                          icon: const Icon(Icons.clear),
                          onPressed: _clearSearch,
                          tooltip: l10n.clear,
                        ),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: _handleSearchInput,
                onSubmitted: (_) => _moveToSearchMatch(1),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 48,
              child: Text(
                resultLabel,
                key: const ValueKey('text-preview-search-count'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            IconButton(
              key: const ValueKey('text-preview-search-previous'),
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: hasMatches ? () => _moveToSearchMatch(-1) : null,
              tooltip: l10n.previousPage,
            ),
            IconButton(
              key: const ValueKey('text-preview-search-next'),
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: hasMatches ? () => _moveToSearchMatch(1) : null,
              tooltip: l10n.nextPage,
            ),
            IconButton(
              key: const ValueKey('text-preview-search-close'),
              icon: const Icon(Icons.close),
              onPressed: _closeSearch,
              tooltip: l10n.close,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewContent(String content) {
    final validMatches = _searchMatches
        .where((match) => match.start >= 0 && match.end <= content.length)
        .toList(growable: false);
    if (!_isSearchMode || validMatches.isEmpty) {
      return KeyedSubtree(
        key: _previewContentKey,
        child: SelectableText(
          content,
          key: const ValueKey('text-preview-content'),
          style: _contentTextStyle,
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (var index = 0; index < validMatches.length; index++) {
      final match = validMatches[index];
      if (match.start > cursor) {
        spans.add(TextSpan(text: content.substring(cursor, match.start)));
      }

      final isCurrent = index == _currentSearchMatchIndex;
      spans.add(
        TextSpan(
          text: content.substring(match.start, match.end),
          style: TextStyle(
            backgroundColor: isCurrent
                ? colorScheme.primaryContainer
                : colorScheme.tertiaryContainer.withValues(alpha: 0.7),
            color: isCurrent ? colorScheme.onPrimaryContainer : null,
            fontWeight: isCurrent ? FontWeight.w700 : null,
          ),
        ),
      );
      cursor = match.end;
    }

    if (cursor < content.length) {
      spans.add(TextSpan(text: content.substring(cursor)));
    }

    return KeyedSubtree(
      key: _previewContentKey,
      child: SelectableText.rich(
        TextSpan(children: spans),
        key: const ValueKey('text-preview-content'),
        style: _contentTextStyle,
      ),
    );
  }

  Widget _buildSearchMarkerRail() {
    final colorScheme = Theme.of(context).colorScheme;
    final currentResult = _currentSearchMatchIndex + 1;
    final label =
        '${S.of(context).search}: $currentResult/${_searchMatches.length}';

    return SizedBox(
      key: const ValueKey('text-preview-search-marker-rail'),
      width: 32,
      child: Semantics(
        button: true,
        label: S.of(context).search,
        value: '$currentResult/${_searchMatches.length}',
        onTap: () => _selectSearchMatch(_currentSearchMatchIndex),
        child: Tooltip(
          message: label,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) =>
                _selectNearestSearchMarker(details.localPosition.dy),
            child: CustomPaint(
              painter: _TextSearchMarkerPainter(
                markers: _searchMarkers,
                currentMatchIndex: _currentSearchMatchIndex,
                currentColor: colorScheme.primary,
                otherColor: colorScheme.tertiary,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadTextContent() async {
    final l10n = S.of(context);
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 优先检查是否是本地文件（file:// 协议）
      final localPath = LocalFileUrl.pathFromUrl(widget.textUrl);
      if (localPath != null) {
        final localFile = File(localPath);

        if (await localFile.exists()) {
          // 使用智能编码检测读取文件
          final content = await _readFileWithEncoding(localFile);
          if (!mounted) return;
          String? translated;
          String? translationTargetKey;
          if (GeneratedSubtitleStore.isGeneratedOriginalPath(localPath)) {
            final targetLocale = await ref.read(
              effectiveTranslationTargetLocaleProvider.future,
            );
            if (!mounted) return;
            translationTargetKey = GeneratedSubtitleStore.targetLanguageKey(
              targetLocale,
            );
            translated = ref
                .read(lyricControllerProvider.notifier)
                .generatedTranslationContent(
                  localPath,
                  targetLocale: targetLocale,
                );
            if (translated == null) {
              try {
                final translatedPath = await const GeneratedSubtitleStore()
                    .findTranslation(localPath, targetLocale: targetLocale);
                if (translatedPath != null) {
                  translated = await File(translatedPath).readAsString();
                }
              } on FileSystemException {
                // The original remains readable if the optional translation is removed.
              }
            }
            if (!mounted) return;
            final latestTarget = await ref.read(
              effectiveTranslationTargetLocaleProvider.future,
            );
            if (translationTargetKey !=
                GeneratedSubtitleStore.targetLanguageKey(latestTarget)) {
              translated = null;
            }
          }
          if (!mounted) return;
          setState(() {
            _content = content;
            _textController.text = content;
            _translatedContent = translated;
            _translationTargetKey = translated == null
                ? null
                : translationTargetKey;
            _translatedTextController.text = translated ?? '';
            _showTranslation = translated != null;
            _isLoading = false;
          });
          _showInitialSaveOptionsIfNeeded();
          _maybeAutoTranslateContent();
          return;
        } else {
          if (!mounted) return;
          setState(() {
            _errorMessage = l10n.localFileNotExist;
            _isLoading = false;
          });
          return;
        }
      }

      if (widget.workId != null &&
          widget.hash != null &&
          widget.hash!.isNotEmpty) {
        final cachedContent = await CacheService.getCachedTextContent(
          workId: widget.workId!,
          hash: widget.hash!,
          fileName: null, // TextPreviewScreen doesn't track fileName
        );

        if (cachedContent != null) {
          if (!mounted) return;
          setState(() {
            _content = cachedContent;
            _textController.text = cachedContent;
            _isLoading = false;
          });
          _showInitialSaveOptionsIfNeeded();
          _maybeAutoTranslateContent();
          return;
        }
      }

      final uri = Uri.parse(widget.textUrl);
      final remoteLease = CacheService.remoteTextLoader.acquire(
        uri: uri,
        key: CacheService.remoteAssetKey(
          kind: RemoteAssetKind.subtitle,
          identity: widget.hash == null || widget.hash!.isEmpty
              ? RemoteAssetKey.canonicalUri(uri)
              : widget.hash!,
        ),
        headers: StorageService.serverCookieHeaders,
      );
      _remoteTextLease = remoteLease;
      late final RemoteTextContent remote;
      try {
        remote = await remoteLease.content;
      } finally {
        if (identical(_remoteTextLease, remoteLease)) {
          _remoteTextLease = null;
        }
        await remoteLease.release();
      }
      _detectedEncoding = remote.encoding;

      if (!mounted) return;
      setState(() {
        _content = remote.text;
        _textController.text = remote.text;
        _isLoading = false;
      });
      _showInitialSaveOptionsIfNeeded();
      _maybeAutoTranslateContent();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = l10n.loadTextFailed(e.toString());
        _isLoading = false;
      });
    }
  }

  Future<void> _translateContent() async {
    final sourceContent = _textController.text;
    if (sourceContent.isEmpty) return;
    final generation = ++_translationGeneration;

    final l10n = S.of(context);
    setState(() {
      _isTranslating = true;
      _translationProgress = l10n.preparingTranslation;
    });

    try {
      final targetLocale = await ref.read(
        effectiveTranslationTargetLocaleProvider.future,
      );
      if (!mounted || generation != _translationGeneration) return;
      final targetKey = GeneratedSubtitleStore.targetLanguageKey(targetLocale);
      _translationTargetKey = targetKey;
      final translateContent = widget.translateContentForTesting;
      final translated = translateContent == null
          ? await TranslationService().translateLongText(
              sourceContent,
              targetLocale: targetLocale,
              onProgress: (current, total) {
                if (!mounted || generation != _translationGeneration) return;
                setState(() {
                  _translationProgress = l10n.translatingProgress(
                    current,
                    total,
                  );
                });
              },
            )
          : await translateContent(sourceContent);

      if (!mounted || generation != _translationGeneration) return;
      final latestTarget = await ref.read(
        effectiveTranslationTargetLocaleProvider.future,
      );
      if (!mounted || generation != _translationGeneration) return;
      if (targetKey != GeneratedSubtitleStore.targetLanguageKey(latestTarget)) {
        setState(() => _isTranslating = false);
        return;
      }
      if (_textController.text != sourceContent) {
        setState(() {
          _isTranslating = false;
          _translationProgress = '';
        });
        return;
      }
      setState(() {
        _translatedContent = translated;
        _translatedTextController.text = translated;
        _showTranslation = true;
        _isTranslating = false;
        _translationProgress = '';
      });
      _refreshSearchResults();
      await _autoSaveTranslatedContentIfEnabled(
        sourceContent,
        translated,
        generation,
        targetLocale,
      );
    } catch (e) {
      if (!mounted || generation != _translationGeneration) return;
      setState(() {
        _isTranslating = false;
        _translationProgress = '';
      });
      SnackBarUtil.showError(context, l10n.translationFailed(e.toString()));
    }
  }

  Future<void> _autoSaveTranslatedContentIfEnabled(
    String sourceContent,
    String translatedContent,
    int generation,
    Locale targetLocale,
  ) async {
    if (translatedContent.isEmpty ||
        translatedContent == sourceContent ||
        !FileIconUtils.isLyricFile(widget.title)) {
      return;
    }

    try {
      final enabled = await ref
          .read(autoSaveTranslatedLyricsProvider.notifier)
          .resolvedEnabled();
      bool isCurrent() =>
          generation == _translationGeneration &&
          _textController.text == sourceContent;
      if (!enabled || !isCurrent()) return;

      final originalPath = LocalFileUrl.pathFromUrl(widget.textUrl);
      if (originalPath != null &&
          GeneratedSubtitleStore.isGeneratedOriginalPath(originalPath)) {
        await const GeneratedSubtitleStore().saveTranslation(
          originalPath,
          translatedContent,
          targetLocale: targetLocale,
          cancelToken: CancelToken(),
        );
      } else {
        await _writeSubtitleToLibrary(
          translatedContent,
          shouldWrite: isCurrent,
        );
      }
      if (mounted && isCurrent()) widget.onSavedToLibrary?.call();
    } catch (e) {
      LogService.instance.error(
        'Failed to save translated subtitle: $e',
        tag: 'TextPreview',
      );
    }
  }

  void _maybeAutoTranslateContent() {
    final localPath = LocalFileUrl.pathFromUrl(widget.textUrl);
    if (!widget.autoTranslate ||
        (localPath != null &&
            GeneratedSubtitleStore.isGeneratedOriginalPath(localPath)) ||
        _autoTranslationStarted ||
        !FileIconUtils.isLyricFile(widget.title) ||
        _content == null ||
        _content!.isEmpty) {
      return;
    }

    _autoTranslationStarted = true;
    unawaited(_translateContent());
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    final locale = Localizations.localeOf(context);
    if (_lastTextScaler != textScaler ||
        _lastTextDirection != textDirection ||
        _lastTextLocale != locale) {
      _lastTextScaler = textScaler;
      _lastTextDirection = textDirection;
      _lastTextLocale = locale;
      _scheduleSearchMarkerLayout();
    }

    ref.listen(effectiveTranslationTargetLocaleProvider, (_, next) {
      final target = next.valueOrNull;
      if (target == null ||
          _translationTargetKey == null ||
          _translationTargetKey ==
              GeneratedSubtitleStore.targetLanguageKey(target)) {
        return;
      }
      setState(() {
        _translationGeneration++;
        _translatedContent = null;
        _translatedTextController.clear();
        _translationTargetKey = null;
        _showTranslation = false;
        _isTranslating = false;
        _translationProgress = '';
      });
      _refreshSearchResults();
    });
    return Scaffold(
      appBar: ScrollableAppBar(
        title: Text(widget.title),
        bottom: _isSearchMode
            ? PreferredSize(
                preferredSize: const Size.fromHeight(60),
                child: _buildSearchBar(),
              )
            : null,
        actions: [
          if (_content != null && _content!.isNotEmpty)
            IconButton(
              key: const ValueKey('text-preview-search-action'),
              icon: Icon(
                Icons.search,
                color: _isSearchMode
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              onPressed: _toggleSearch,
              tooltip: S.of(context).search,
            ),
          if (_content != null && _content!.isNotEmpty)
            IconButton(
              icon: Icon(
                _isEditMode ? Icons.visibility : Icons.edit,
                color: _isEditMode
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              onPressed: () {
                setState(() {
                  _isEditMode = !_isEditMode;
                });
                _refreshSearchResults();
              },
              tooltip: _isEditMode
                  ? S.of(context).previewMode
                  : S.of(context).editMode,
            ),
          if (_content != null && _content!.isNotEmpty)
            TranslationToolbarButton(
              isTranslated: _showTranslation,
              isLoading: _isTranslating,
              onPressed: _isTranslating
                  ? null
                  : () {
                      if (_translatedContent != null) {
                        setState(() {
                          _showTranslation = !_showTranslation;
                        });
                        _refreshSearchResults();
                      } else {
                        _translateContent();
                      }
                    },
              tooltip: _showTranslation
                  ? S.of(context).showOriginal
                  : S.of(context).translateContent,
            ),
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _showSaveOptions,
            tooltip: S.of(context).save,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadTextContent,
              child: Text(S.of(context).retry),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        LinearProgressIndicator(
          value: _scrollProgress,
          backgroundColor: Colors.grey[300],
          valueColor: AlwaysStoppedAnimation<Color>(
            Theme.of(context).colorScheme.primary,
          ),
          minHeight: 3,
        ),
        if (_isTranslating)
          Container(
            padding: const EdgeInsets.all(8),
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(_translationProgress),
              ],
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final viewportSize = Size(
                constraints.maxWidth,
                constraints.maxHeight,
              );
              if (_lastSearchViewportSize != viewportSize) {
                _lastSearchViewportSize = viewportSize;
                _scheduleSearchMarkerLayout();
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: true,
                      child: NotificationListener<ScrollMetricsNotification>(
                        onNotification: (_) {
                          _scheduleSearchMarkerLayout();
                          return false;
                        },
                        child: SingleChildScrollView(
                          key: _scrollViewportKey,
                          controller: _scrollController,
                          padding: const EdgeInsets.all(16),
                          child: _isEditMode
                              ? KeyedSubtree(
                                  key: _editContentKey,
                                  child: TextField(
                                    key: const ValueKey(
                                      'text-preview-edit-field',
                                    ),
                                    controller:
                                        _showTranslation &&
                                            _translatedContent != null
                                        ? _translatedTextController
                                        : _textController,
                                    focusNode: _editFocusNode,
                                    maxLines: null,
                                    style: _contentTextStyle,
                                    decoration: InputDecoration(
                                      border: const OutlineInputBorder(),
                                      hintText: S
                                          .of(context)
                                          .editTextContentHint,
                                    ),
                                    onChanged: (value) {
                                      if (!(_showTranslation &&
                                          _translatedContent != null)) {
                                        _translationGeneration++;
                                        final updateScreen =
                                            _translatedContent != null ||
                                            _showTranslation ||
                                            _isTranslating ||
                                            _translationProgress.isNotEmpty ||
                                            (_content?.isEmpty ?? true) !=
                                                value.isEmpty;
                                        if (updateScreen) {
                                          setState(() {
                                            _content = value;
                                            _translatedContent = null;
                                            _translatedTextController.clear();
                                            _showTranslation = false;
                                            _isTranslating = false;
                                            _translationProgress = '';
                                          });
                                        } else {
                                          _content = value;
                                        }
                                      }
                                      _refreshSearchResults();
                                    },
                                  ),
                                )
                              : _buildPreviewContent(
                                  _getCurrentContent() ?? '',
                                ),
                        ),
                      ),
                    ),
                  ),
                  if (_isSearchMode && _searchMatches.isNotEmpty)
                    _buildSearchMarkerRail(),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TextSearchMatch {
  const _TextSearchMatch(this.start, this.end);

  final int start;
  final int end;
}

class _TextSearchMarker {
  const _TextSearchMarker({
    required this.position,
    required this.firstMatchIndex,
    required this.lastMatchIndex,
  });

  final double position;
  final int firstMatchIndex;
  final int lastMatchIndex;
}

class _TextSearchMarkerPainter extends CustomPainter {
  const _TextSearchMarkerPainter({
    required this.markers,
    required this.currentMatchIndex,
    required this.currentColor,
    required this.otherColor,
  });

  final List<_TextSearchMarker> markers;
  final int currentMatchIndex;
  final Color currentColor;
  final Color otherColor;

  @override
  void paint(Canvas canvas, Size size) {
    bool isCurrent(_TextSearchMarker marker) =>
        currentMatchIndex >= marker.firstMatchIndex &&
        currentMatchIndex <= marker.lastMatchIndex;

    void paintMarker(_TextSearchMarker marker, Color color) {
      final centerY = (marker.position * size.height)
          .clamp(2.0, size.height - 2.0)
          .toDouble();
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(size.width / 2, centerY),
            width: 8,
            height: 4,
          ),
          const Radius.circular(2),
        ),
        Paint()..color = color,
      );
    }

    for (final marker in markers) {
      if (!isCurrent(marker)) paintMarker(marker, otherColor);
    }
    for (final marker in markers) {
      if (isCurrent(marker)) paintMarker(marker, currentColor);
    }
  }

  @override
  bool shouldRepaint(_TextSearchMarkerPainter oldDelegate) =>
      oldDelegate.markers != markers ||
      oldDelegate.currentMatchIndex != currentMatchIndex ||
      oldDelegate.currentColor != currentColor ||
      oldDelegate.otherColor != otherColor;
}

List<_TextSearchMatch> _findTextMatches(String content, String query) {
  final normalizedQuery = query.trim();
  if (content.isEmpty || normalizedQuery.isEmpty) return const [];

  final expression = RegExp(
    RegExp.escape(normalizedQuery),
    caseSensitive: false,
    unicode: true,
  );
  return expression
      .allMatches(content)
      .map((match) => _TextSearchMatch(match.start, match.end))
      .toList(growable: false);
}

class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);

  @override
  String toString() => message;
}
