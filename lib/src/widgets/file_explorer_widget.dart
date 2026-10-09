import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../models/audio_tap_playlist_mode.dart';
import '../models/work.dart';
import '../models/download_task_change.dart';
import '../providers/auth_provider.dart';
import '../providers/download_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/lyric_provider.dart';
import '../providers/settings_provider.dart';
import '../services/download_service.dart';
import '../services/download_file_path_service.dart';
import '../services/cache_service.dart';
import '../services/log_service.dart';
import '../services/translation_service.dart';
import '../services/subtitle_match_loader.dart';
import '../services/audio_playback_plan_builder.dart';
import '../services/file_preview_resolver.dart';
import '../services/downloaded_file_state_scanner.dart';
import '../services/audio_file_url_resolver.dart';
import '../services/video_file_opener.dart';
import '../services/file_name_translation_service.dart';
import '../services/file_name_translation_controller.dart';
import '../services/file_explorer_tap_resolver.dart';
import '../services/player_audio_variant_classifier.dart';
import '../utils/file_icon_utils.dart';
import '../utils/file_tree_utils.dart';
import '../utils/l10n_extensions.dart';
import '../utils/snackbar_util.dart';
import '../utils/string_utils.dart';
import 'file_tree_actions.dart';
import 'file_tree_view.dart';
import 'file_explorer_tree_panel.dart';
import 'work_image_reader.dart';
import 'work_resource_tabs.dart';
import 'work_detail/recommendation_section.dart';
import 'manual_subtitle_load_flow.dart';
import 'text_preview_screen.dart';
import 'pdf_preview_screen.dart';
import 'video_open_failure_dialog.dart';

final _log = LogService.instance;

final downloadedFileStateScannerProvider = Provider((ref) {
  final service = DownloadService.instance;
  return DownloadedFileStateScanner(
    resolveDownloadedPath: service.getDownloadedFilePath,
    downloadRootPath: () async => (await service.getDownloadDirectory()).path,
  );
});

class FileExplorerController {
  _FileExplorerWidgetState? _state;

  bool get isAttached => _state != null;

  Future<void> refresh({bool forceRefresh = false}) async {
    final state = _state;
    if (state == null) throw StateError('File explorer is not attached');

    await state._loadWorkTree(forceRefresh: forceRefresh, propagateError: true);
  }

  void _attach(_FileExplorerWidgetState state) {
    _state = state;
  }

  void _detach(_FileExplorerWidgetState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }
}

class FileExplorerWidget extends ConsumerStatefulWidget {
  final Work work;
  final Work Function()? currentWork;
  final VoidCallback? onLoadCompleted;
  final WidgetBuilder? recommendationBuilder;
  final FileExplorerController? controller;
  final Future<bool> Function()? initialLoadReady;
  final bool translate;

  const FileExplorerWidget({
    super.key,
    required this.work,
    this.currentWork,
    this.onLoadCompleted,
    this.recommendationBuilder,
    this.controller,
    this.initialLoadReady,
    this.translate = false,
  });

  @override
  ConsumerState<FileExplorerWidget> createState() => _FileExplorerWidgetState();
}

class _FileExplorerWidgetState extends ConsumerState<FileExplorerWidget> {
  Work get _work => widget.currentWork?.call() ?? widget.work;
  List<dynamic> _rootFiles = [];
  final Set<String> _expandedFolders = {}; // 记录展开的文件夹路径
  final Map<String, bool> _manualFolderOverrides = {};
  final _audioVariantClassifier = const PlayerAudioVariantClassifier();
  List<PlayerAudioVariant> _audioVariants = const [];
  final Map<String, bool> _downloadedFiles = {}; // hash -> downloaded
  Map<String, String> _fileRelativePaths = {}; // hash -> relative path
  final Set<String> _audioWithLibrarySubtitles = {}; // 存储在字幕库中有匹配字幕的音频文件名
  bool _isLoading = true;
  String? _errorMessage;
  bool _audioVariantsReady = false;
  int _preferenceUpdateGeneration = 0;
  StreamSubscription<DownloadTaskChange>? _downloadTasksSubscription;
  int _loadGeneration = 0;
  bool _downloadScanRunning = false;
  bool _downloadScanRequested = false;
  List<String> _visibleNames = const [];

  FilePreviewResolver get _previewResolver => FilePreviewResolver(
    downloadRootPath: () async {
      final downloadDir = await DownloadService.instance.getDownloadDirectory();
      return downloadDir.path;
    },
  );

  DownloadedFileStateScanner get _downloadedFileScanner =>
      ref.read(downloadedFileStateScannerProvider);

  AudioFileUrlResolver get _audioUrlResolver {
    final downloadService = DownloadService.instance;
    return AudioFileUrlResolver(
      resolveDownloadedPath: downloadService.getDownloadedFilePath,
      downloadRootPath: () async {
        final downloadDir = await downloadService.getDownloadDirectory();
        return downloadDir.path;
      },
      resolveCachedAudioPath: CacheService.getCachedAudioFile,
    );
  }

  final VideoFileOpener _videoFileOpener = VideoFileOpener();
  final SubtitleMatchLoader _subtitleMatchLoader = const SubtitleMatchLoader();
  final FileExplorerTapResolver _tapResolver = const FileExplorerTapResolver(
    videoBeforeAudio: true,
  );
  final AudioPlaybackPlanBuilder _audioPlaybackPlanBuilder =
      const AudioPlaybackPlanBuilder();
  final FileNameTranslationController _translationController =
      FileNameTranslationController();

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    ref.listenManual(audioFormatPreferenceProvider, (previous, preference) {
      unawaited(_syncPreferredExpandedFolders(preference));
    });
    _loadWorkTree();
    // 监听下载任务变化
    _listenToDownloadTasks();
  }

  @override
  void didUpdateWidget(covariant FileExplorerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.translate && widget.translate) {
      unawaited(_translateVisibleNames());
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _loadGeneration++;
    _translationController.dispose();
    _downloadTasksSubscription?.cancel();
    super.dispose();
  }

  bool _isCurrentLoad(int generation) {
    return mounted && generation == _loadGeneration;
  }

  Future<bool> _waitForLoadReady() async {
    return await widget.initialLoadReady?.call() ?? true;
  }

  // 监听下载任务变化，当有任务完成或被删除时重新检测
  void _listenToDownloadTasks() {
    final downloadService = ref.read(downloadServiceProvider);
    _downloadTasksSubscription = downloadService.taskChangesStream.listen((
      change,
    ) {
      final isReset = change.type == DownloadTaskChangeType.reset;
      final affectsCurrentWork =
          change.task?.workId == _work.id ||
          change.previousTask?.workId == _work.id;
      final statusChanged = change.previousTask?.status != change.task?.status;
      if (isReset ||
          (affectsCurrentWork && (change.isStructural || statusChanged))) {
        _checkDownloadedFiles();
      }
    });
  }

  Future<void> _loadWorkTree({
    bool forceRefresh = false,
    bool propagateError = false,
  }) async {
    final generation = ++_loadGeneration;
    final preserveCurrentTree = forceRefresh && _rootFiles.isNotEmpty;
    if (!preserveCurrentTree) _audioVariantsReady = false;
    var mayPublishCompletion = false;

    try {
      if (!await _waitForLoadReady() || !_isCurrentLoad(generation)) return;
      setState(() {
        _isLoading = !preserveCurrentTree;
        _errorMessage = null;
      });

      final apiService = ref.read(kikoeruApiServiceProvider);
      final files = await apiService.getWorkTracks(
        _work.id,
        forceRefresh: forceRefresh,
      );
      if (!_isCurrentLoad(generation)) return;
      if (!await _waitForLoadReady() || !_isCurrentLoad(generation)) return;
      final audioVariants = _audioVariantClassifier.scan(
        files,
        workTitle: _work.title,
      );

      // 注意：不要在这里更新全局文件列表
      // 只在播放音频时才更新，避免浏览其他作品时影响当前播放的歌曲?

      setState(() {
        _rootFiles = files;
        _audioVariants = audioVariants;
        _audioVariantsReady = false;
        _fileRelativePaths = DownloadedFileStateScanner.collectFilePaths(files);
        _isLoading = false;
      });

      // 检查已下载的文件
      unawaited(_checkDownloadedFiles());

      // 检查字幕库中的匹配项
      if (!await _checkLibrarySubtitles(generation)) return;
      if (!await _waitForLoadReady() || !_isCurrentLoad(generation)) return;

      await ref.read(audioFormatPreferenceProvider.notifier).getPreference();
      if (!await _waitForLoadReady() || !_isCurrentLoad(generation)) return;

      // 与原有流程保持一致，在字幕匹配准备完成后再自动展开目录。
      _audioVariantsReady = true;
      setState(() {
        _applyPreferredExpandedFolders(ref.read(audioFormatPreferenceProvider));
      });
      mayPublishCompletion = true;
    } catch (e) {
      if (!_isCurrentLoad(generation)) return;
      if (!await _waitForLoadReady() || !_isCurrentLoad(generation)) return;
      setState(() {
        if (!preserveCurrentTree) {
          _errorMessage = S.of(context).loadFilesFailed(e.toString());
        }
        _isLoading = false;
      });
      mayPublishCompletion = true;
      if (propagateError) rethrow;
    } finally {
      if (mayPublishCompletion && _isCurrentLoad(generation)) {
        widget.onLoadCompleted?.call();
      }
    }
  }

  // 检查已下载的文件
  Future<void> _checkDownloadedFiles() async {
    _downloadScanRequested = true;
    if (_downloadScanRunning) return;
    _downloadScanRunning = true;
    try {
      while (mounted && _downloadScanRequested) {
        _downloadScanRequested = false;
        final generation = _loadGeneration;
        if (!await _waitForLoadReady() || !mounted) return;
        if (_downloadScanRequested || generation != _loadGeneration) continue;
        final DownloadedFileState result;
        try {
          result = await _downloadedFileScanner.scan(
            workId: _work.id,
            fileTree: _rootFiles,
            fileRelativePaths: _fileRelativePaths,
          );
        } catch (e) {
          _log.captureOutput('[FileExplorer] 检查已下载文件失败: $e');
          if (_downloadScanRequested) continue;
          return;
        }
        if (!mounted) return;
        if (!await _waitForLoadReady() || !mounted) return;
        if (_downloadScanRequested) continue;
        if (generation != _loadGeneration) continue;
        if (mapEquals(_downloadedFiles, result.downloadedFiles)) continue;
        setState(() {
          _downloadedFiles
            ..clear()
            ..addAll(result.downloadedFiles);
        });
      }
    } finally {
      _downloadScanRunning = false;
    }
  }

  // 检查字幕库中哪些音频文件有匹配的字幕
  Future<bool> _checkLibrarySubtitles(int generation) async {
    try {
      if (!await _waitForLoadReady() || !_isCurrentLoad(generation)) {
        return false;
      }
      final matches = await _subtitleMatchLoader.loadMatches(
        workId: _work.id,
        fileTree: _rootFiles,
      );
      if (!_isCurrentLoad(generation)) return false;
      if (!await _waitForLoadReady() || !_isCurrentLoad(generation)) {
        return false;
      }

      _audioWithLibrarySubtitles
        ..clear()
        ..addAll(matches);

      _log.captureOutput(
        '[FileExplorer] 字幕库匹配: ${_audioWithLibrarySubtitles.length} 个音频文件有字幕',
      );
      return true;
    } catch (e) {
      _log.captureOutput('[FileExplorer] 检查字幕库失败: $e');
      return _isCurrentLoad(generation);
    }
  }

  Future<void> _syncPreferredExpandedFolders(
    AudioFormatPreference preference,
  ) async {
    if (!_audioVariantsReady) return;
    final generation = _loadGeneration;
    final preferenceGeneration = ++_preferenceUpdateGeneration;
    if (!await _waitForLoadReady() ||
        !_isCurrentLoad(generation) ||
        !_audioVariantsReady ||
        preferenceGeneration != _preferenceUpdateGeneration) {
      return;
    }
    setState(() => _applyPreferredExpandedFolders(preference));
  }

  void _applyPreferredExpandedFolders(AudioFormatPreference preference) {
    final preferredPaths = _audioVariantClassifier.preferredExpandedPaths(
      _audioVariants,
      preference: preference,
    );
    _expandedFolders
      ..clear()
      ..addAll(
        preferredPaths.where((path) => _manualFolderOverrides[path] != false),
      )
      ..addAll(
        _manualFolderOverrides.entries
            .where((entry) => entry.value)
            .map((entry) => entry.key),
      );
  }

  // 切换文件夹展开/折叠状态
  void _toggleFolder(String path) {
    setState(() {
      if (_expandedFolders.contains(path)) {
        _expandedFolders.remove(path);
        _manualFolderOverrides[path] = false;
      } else {
        _expandedFolders.add(path);
        _manualFolderOverrides[path] = true;
      }
    });
  }

  Future<void> _playAudioFile(
    dynamic audioFile,
    String parentPath, {
    AudioTapPlaylistMode? modeOverride,
    List<dynamic>? audioFiles,
  }) async {
    final l10n = S.of(context);
    final authState = ref.read(authProvider);
    final host = authState.host ?? '';
    final token = authState.token ?? '';
    final coverUrl = host.isEmpty
        ? null
        : _work.getCoverImageUrl(host, token: token);
    final title = FileTreeUtils.titleOf(audioFile, defaultValue: l10n.unknown);

    // 获取当前作品的完整文件树（用于字幕查找）
    try {
      final apiService = ref.read(kikoeruApiServiceProvider);
      final allFiles = await apiService.getWorkTracks(_work.id);

      // 只在播放音频时更新全局文件列表，这样字幕才能正确关联
      ref
          .read(fileListControllerProvider.notifier)
          .updateFiles(allFiles, workId: _work.id);
    } catch (e) {
      _log.captureOutput('获取完整文件树失败 $e');
      // 即使获取失败也继续播放，只是可能没有字幕
    }

    if (!mounted) return;

    final playlistMode =
        modeOverride ??
        await ref.read(audioTapPlaylistModeProvider.notifier).getMode();
    if (!mounted) return;
    final plan = await _audioPlaybackPlanBuilder.build(
      fileTree: _rootFiles,
      parentPath: parentPath,
      selectedFile: audioFile,
      resolveUrl: (file) => _audioUrlResolver.resolveOnline(
        file: file,
        workId: _work.id,
        host: host,
        token: token,
        downloadedFiles: _downloadedFiles,
        fileRelativePaths: _fileRelativePaths,
      ),
      work: _work,
      unknownTitle: l10n.unknown,
      artworkUrl: coverUrl,
      playlistMode: playlistMode,
      audioFiles: audioFiles,
    );

    if (!mounted) return;

    switch (plan.status) {
      case AudioPlaybackPlanStatus.selectedFileMissing:
        SnackBarUtil.showError(
          context,
          l10n.cannotFindAudioFile(plan.selectedTitle),
          duration: const Duration(seconds: 3),
        );
        return;
      case AudioPlaybackPlanStatus.emptyQueue:
        SnackBarUtil.showError(
          context,
          l10n.noPlayableAudioFiles,
          duration: const Duration(seconds: 3),
        );
        return;
      case AudioPlaybackPlanStatus.ready:
        final queue = plan.queue!;
        _log.captureOutput('播放音频: $title');
        _log.captureOutput('播放队列包含 ${queue.tracks.length} 个文件');

        try {
          await ref
              .read(audioPlayerControllerProvider.notifier)
              .playTracks(
                queue.tracks,
                startIndex: queue.startIndex,
                work: _work,
                playlistMode: playlistMode,
              );
          if (mounted && playlistMode != AudioTapPlaylistMode.replaceQueue) {
            SnackBarUtil.showSuccess(
              context,
              playlistMode.localizedName(context),
            );
          }
        } catch (e) {
          _log.captureOutput('播放音频失败: $e');
          if (mounted) {
            SnackBarUtil.showError(context, l10n.playbackFailed(e.toString()));
          }
        }
    }

    // 注意：字幕会通过 lyricAutoLoaderProvider 自动加载
    // 不需要手动调用 loadLyricForTrack
  }

  Future<void> _copyFileName(String title) async {
    await Clipboard.setData(ClipboardData(text: title));
    if (!mounted) return;
    SnackBarUtil.showSuccess(context, S.of(context).copiedName(title));
  }

  Future<void> _downloadSingleFile(dynamic file, String parentPath) async {
    final l10n = S.of(context);
    final title = FileTreeUtils.titleOf(file, defaultValue: l10n.unknown);
    final hash = FileTreeUtils.property(file, 'hash')?.toString();
    if (hash == null || hash.isEmpty) {
      SnackBarUtil.showError(context, l10n.downloadFailed);
      return;
    }

    final auth = ref.read(authProvider);
    final host = auth.host ?? '';
    final token = auth.token ?? '';
    var downloadUrl =
        FileTreeUtils.property(file, 'mediaDownloadUrl')?.toString() ?? '';
    final normalizedHost = _normalizedHost(host);
    if (downloadUrl.startsWith('/') && normalizedHost.isNotEmpty) {
      downloadUrl = '$normalizedHost$downloadUrl';
    }
    if (downloadUrl.isEmpty && normalizedHost.isNotEmpty) {
      downloadUrl =
          '$normalizedHost/api/media/download/$hash/'
          '${Uri.encodeComponent(title)}?token=$token';
    } else if (downloadUrl.isNotEmpty &&
        token.isNotEmpty &&
        !downloadUrl.contains('token=')) {
      downloadUrl += downloadUrl.contains('?')
          ? '&token=$token'
          : '?token=$token';
    }
    if (downloadUrl.isEmpty) {
      SnackBarUtil.showError(context, l10n.downloadFailed);
      return;
    }

    final workMetadata = Map<String, dynamic>.from(_work.toJson());
    final annotatedTree =
        DownloadFilePathService.annotateFileTreeWithLocalPaths(_rootFiles);
    if (annotatedTree.isNotEmpty) workMetadata['children'] = annotatedTree;
    final size = FileTreeUtils.property(file, 'size');
    final coverUrl = host.isEmpty
        ? null
        : _work.getCoverImageUrl(host, token: token);
    try {
      await DownloadService.instance.addTask(
        workId: _work.id,
        workTitle: _work.title,
        fileName: title,
        relativePath: parentPath,
        downloadUrl: downloadUrl,
        hash: hash,
        totalBytes: size is num ? size.toInt() : null,
        workMetadata: workMetadata,
        coverUrl: coverUrl,
      );
      if (!mounted) return;
      SnackBarUtil.showSuccess(context, l10n.addedNFilesToDownloadQueue(1));
    } catch (error) {
      if (!mounted) return;
      SnackBarUtil.showError(context, '${l10n.downloadFailed}: $error');
    }
  }

  String _normalizedHost(String host) {
    if (host.isEmpty ||
        host.startsWith('http://') ||
        host.startsWith('https://')) {
      return host;
    }
    if (host.contains('localhost') ||
        host.startsWith('127.0.0.1') ||
        host.startsWith('192.168.')) {
      return 'http://$host';
    }
    return 'https://$host';
  }

  Future<void> _showFileActionMenu(
    dynamic file,
    String displayTitle,
    String parentPath, {
    List<dynamic>? audioFiles,
  }) async {
    final isAudio = FileIconUtils.isAudioFile(file);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: false,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isAudio) ...[
              ListTile(
                key: const ValueKey('file-action-add-to-queue'),
                leading: const Icon(Icons.playlist_add),
                title: Text(
                  AudioTapPlaylistMode.addToQueue.localizedName(context),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _playAudioFile(
                    file,
                    parentPath,
                    modeOverride: AudioTapPlaylistMode.addToQueue,
                    audioFiles: audioFiles,
                  );
                },
              ),
              ListTile(
                key: const ValueKey('file-action-play-next'),
                leading: const Icon(Icons.queue_play_next),
                title: Text(
                  AudioTapPlaylistMode.playNext.localizedName(context),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _playAudioFile(
                    file,
                    parentPath,
                    modeOverride: AudioTapPlaylistMode.playNext,
                    audioFiles: audioFiles,
                  );
                },
              ),
              ListTile(
                key: const ValueKey('file-action-replace-queue'),
                leading: const Icon(Icons.playlist_play),
                title: Text(
                  AudioTapPlaylistMode.replaceQueue.localizedName(context),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _playAudioFile(
                    file,
                    parentPath,
                    modeOverride: AudioTapPlaylistMode.replaceQueue,
                    audioFiles: audioFiles,
                  );
                },
              ),
            ],
            ListTile(
              key: const ValueKey('file-action-download'),
              leading: const Icon(Icons.download_outlined),
              title: Text(S.of(context).download),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _downloadSingleFile(file, parentPath);
              },
            ),
            ListTile(
              key: const ValueKey('file-action-copy-name'),
              leading: const Icon(Icons.copy_outlined),
              title: Text(S.of(context).copyName),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _copyFileName(displayTitle);
              },
            ),
          ],
        ),
      ),
    );
  }

  // 手动加载字幕
  Future<void> _loadLyricManually(dynamic file) async {
    final l10n = S.of(context);
    final title = FileTreeUtils.titleOf(file, defaultValue: l10n.unknown);
    final currentTrack = ref.read(currentTrackProvider).value;

    await runManualSubtitleLoadFlow(
      context,
      file: file,
      workId: _work.id,
      subtitleTitle: title,
      currentAudioTitle: currentTrack?.title,
      loadSubtitle: (file, {required workId}) {
        return ref
            .read(lyricControllerProvider.notifier)
            .loadLyricManually(file, workId: workId);
      },
      isMounted: () => mounted,
      successDuration: const Duration(seconds: 3),
      errorDuration: const Duration(seconds: 4),
    );
  }

  Future<void> _previewImageFile(dynamic file) async {
    final l10n = S.of(context);
    final authState = ref.read(authProvider);
    final host = authState.host ?? '';
    final token = authState.token ?? '';

    final result = await _previewResolver.buildOnlineImageGalleryTarget(
      selectedFile: file,
      imageFiles: _getImageFilesFromCurrentDirectory(),
      workId: _work.id,
      host: host,
      token: token,
      downloadedFiles: _downloadedFiles,
      fileRelativePaths: _fileRelativePaths,
      unknownTitle: l10n.unknown,
    );

    if (!mounted) return;

    switch (result.status) {
      case PreviewImageGalleryStatus.ready:
        final target = result.requireTarget;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => WorkImageReader(
              title: _work.title,
              images: target.toGalleryMaps(),
              initialIndex: target.initialIndex,
            ),
          ),
        );
        return;
      case PreviewImageGalleryStatus.missingOnlineInfo:
        SnackBarUtil.showError(context, l10n.cannotPreviewImageMissingInfo);
        return;
      case PreviewImageGalleryStatus.missingSelectedImage:
        SnackBarUtil.showError(context, l10n.cannotFindImageFile);
        return;
      case PreviewImageGalleryStatus.empty:
        return;
    }
  }

  // 获取当前目录下所有图片文件（递归遍历整个树）
  List<dynamic> _getImageFilesFromCurrentDirectory() {
    return FileTreeUtils.imageFilesRecursive(_rootFiles);
  }

  Future<void> _previewTextFile(dynamic file) async {
    await _previewDocumentFile(file, isPdf: false);
  }

  Future<void> _previewPdfFile(dynamic file) async {
    await _previewDocumentFile(file, isPdf: true);
  }

  Future<void> _previewDocumentFile(dynamic file, {required bool isPdf}) async {
    final authState = ref.read(authProvider);
    final host = authState.host ?? '';
    final token = authState.token ?? '';
    final l10n = S.of(context);
    final result = await _previewResolver.resolveOnlineDocumentTarget(
      file: file,
      workId: _work.id,
      host: host,
      token: token,
      downloadedFiles: _downloadedFiles,
      fileRelativePaths: _fileRelativePaths,
      unknownTitle: l10n.unknown,
    );

    if (!mounted) return;

    switch (result.status) {
      case PreviewDocumentTargetStatus.ready:
        final target = result.requireTarget;
        final autoTranslate = widget.translate;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) {
              if (isPdf) {
                return PdfPreviewScreen(
                  pdfUrl: target.url,
                  title: target.title,
                  workId: _work.id,
                  hash: target.hash,
                );
              }

              return TextPreviewScreen(
                textUrl: target.url,
                title: target.title,
                workId: _work.id,
                hash: target.hash,
                autoTranslate: autoTranslate,
              );
            },
          ),
        );
        return;
      case PreviewDocumentTargetStatus.missingOnlineInfo:
        SnackBarUtil.showError(
          context,
          isPdf
              ? l10n.cannotPreviewPdfMissingInfo
              : l10n.cannotPreviewTextMissingInfo,
        );
        return;
      case PreviewDocumentTargetStatus.unavailable:
      case PreviewDocumentTargetStatus.missingId:
      case PreviewDocumentTargetStatus.missingPath:
      case PreviewDocumentTargetStatus.missingFile:
        return;
    }
  }

  // 使用系统播放器播放视频文件
  Future<void> _playVideoWithSystemPlayer(dynamic videoFile) async {
    final authState = ref.read(authProvider);
    final host = authState.host ?? '';
    final token = authState.token ?? '';

    final targetResult = await _previewResolver.resolveOnlineVideoTarget(
      file: videoFile,
      workId: _work.id,
      host: host,
      token: token,
      downloadedFiles: _downloadedFiles,
      fileRelativePaths: _fileRelativePaths,
    );

    if (!mounted) return;

    switch (targetResult.status) {
      case PreviewVideoTargetStatus.ready:
        final target = targetResult.requireTarget;
        final localPath = target.localPath;
        if (localPath != null) {
          _log.captureOutput('[FileExplorer] 使用本地视频文件: $localPath');
        }

        final result = await _videoFileOpener.open(target.source);
        if (!mounted) return;

        _handleVideoOpenResult(result);
        return;
      case PreviewVideoTargetStatus.missingId:
        SnackBarUtil.showError(context, S.of(context).cannotPlayVideoMissingId);
        return;
      case PreviewVideoTargetStatus.missingParams:
        SnackBarUtil.showError(
          context,
          S.of(context).cannotPlayVideoMissingParams,
        );
        return;
      case PreviewVideoTargetStatus.missingPath:
      case PreviewVideoTargetStatus.missingFile:
        return;
    }
  }

  void _handleVideoOpenResult(VideoOpenResult result) {
    switch (result.type) {
      case VideoOpenResultType.success:
        return;
      case VideoOpenResultType.localOpenFailed:
        showDialog(
          context: context,
          builder: (context) => VideoOpenFailureDialog.local(
            errorMessage: result.message ?? '',
            filePath: result.path ?? '',
          ),
        );
        return;
      case VideoOpenResultType.localOpenError:
        SnackBarUtil.showError(
          context,
          S.of(context).openVideoFileError(result.message ?? ''),
        );
        return;
      case VideoOpenResultType.remoteCannotLaunch:
        final uri = result.uri;
        if (uri == null) return;
        showDialog(
          context: context,
          builder: (context) => VideoOpenFailureDialog.remote(
            videoUrl: uri.toString(),
            onOpenInBrowser: () => _videoFileOpener.openInBrowser(uri),
          ),
        );
        return;
      case VideoOpenResultType.remoteOpenError:
        SnackBarUtil.showError(
          context,
          S.of(context).playVideoError(result.message ?? ''),
        );
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 直接返回文件列表，占满全部空间
    return _buildFileList();
  }

  Widget _buildFileList() {
    final tree = FileExplorerTreePanel(
      isLoading: _isLoading,
      errorMessage: _errorMessage,
      empty: _rootFiles.isEmpty,
      emptyMessage: S.of(context).noFiles,
      onRetry: _loadWorkTree,
      title: S.of(context).resourceFiles,
      items: _rootFiles,
      expandedFolders: _expandedFolders,
      onToggleFolder: _toggleFolder,
      onFileTap: _handleFileTap,
      onFileLongPress: _showFileActionMenu,
      displayNameFor: _getDisplayName,
      metadataBuilder: _buildFileMetadata,
      trailingBuilder: _buildFileActions,
      downloadedFiles: _downloadedFiles,
      audioWithLibrarySubtitles: _audioWithLibrarySubtitles,
      showDownloadedBadge: true,
      fadeDownloadedItems: true,
      showHeader: false,
    );
    if (_isLoading) return tree;
    return WorkResourceTabs(
      workId: _work.id,
      fileTree: _rootFiles,
      audioVariants: _audioVariants,
      resourceSliver: tree,
      resourceTitle: S.of(context).workResources,
      initialTab: _errorMessage == null
          ? WorkResourceTab.audio
          : WorkResourceTab.resources,
      recommendationBuilder:
          widget.recommendationBuilder ??
          (context) => RecommendationSection(work: _work),
      progressMessage: _translationController.isBulkTranslating
          ? _translationController.progress
          : null,
      onPlayAudio: (file, path, files) =>
          _playAudioFile(file, path, audioFiles: files),
      onAudioLongPress: (file, title, path, files) =>
          _showFileActionMenu(file, title, path, audioFiles: files),
      onFileTap: _handleFileTap,
      displayNameFor: _getDisplayName,
      metadataBuilder: _buildFileMetadata,
      downloadedFiles: _downloadedFiles,
      expandedFolders: _expandedFolders,
      onVisibleNamesChanged: _onVisibleNamesChanged,
      onImageTap: _previewImageFile,
      resolveImage: (file) async {
        final auth = ref.read(authProvider);
        final items = await _previewResolver.buildOnlineImageItems(
          imageFiles: [file],
          workId: _work.id,
          host: auth.host ?? '',
          token: auth.token ?? '',
          downloadedFiles: _downloadedFiles,
          fileRelativePaths: _fileRelativePaths,
          unknownTitle: S.of(context).unknown,
        );
        return items.firstOrNull;
      },
    );
  }

  Widget? _buildFileMetadata(BuildContext context, FileTreeEntry entry) {
    final item = entry.item;
    final duration = FileTreeUtils.property(item, 'duration');
    if (duration == null) return null;

    if (!FileIconUtils.isAudioFile(item) && !FileIconUtils.isVideoFile(item)) {
      return null;
    }

    final durationText = formatDurationSeconds(duration, padHours: false);
    if (durationText.isEmpty) return null;

    return Text(
      durationText,
      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
    );
  }

  Widget? _buildFileActions(BuildContext context, FileTreeEntry entry) {
    return FileTreeActions(
      entry: entry,
      onPlayAudio: (item, parentPath) => _playAudioFile(item, parentPath),
      onPlayVideo: (item, _) => _playVideoWithSystemPlayer(item),
      onLoadSubtitle: (item, _) => _loadLyricManually(item),
      onPreviewImage: (item, _) => _previewImageFile(item),
      onPreviewText: (item, _) => _previewTextFile(item),
      onPreviewPdf: (item, _) => _previewPdfFile(item),
    );
  }

  void _onVisibleNamesChanged(List<String> names) {
    _visibleNames = names;
    if (widget.translate) unawaited(_translateVisibleNames());
  }

  Future<void> _translateVisibleNames() async {
    if (!widget.translate ||
        _isLoading ||
        _errorMessage != null ||
        _translationController.isBulkTranslating) {
      return;
    }
    final names = _visibleNames
        .where((name) => !_translationController.translations.containsKey(name))
        .toList(growable: false);
    if (names.isEmpty) return;

    final l10n = S.of(context);
    final generation = _translationController.beginBulkTranslation(
      l10n.preparingTranslation,
    );
    setState(() {});

    try {
      final result = await FileNameTranslationService(
        translate: TranslationService().translate,
      ).translateNames(
        names: names,
        onProgress: (current, total) {
          final updated = _translationController.updateBulkProgress(
            generation,
            l10n.translatingProgress(current, total),
          );
          if (updated && mounted) setState(() {});
        },
        onChunkError: (index, error) {
          _log.captureOutput('[FileExplorer] 翻译块 $index 失败: $error');
        },
      );

      if (!mounted ||
          !_translationController.completeBulkTranslation(
            generation,
            result.translations,
          )) {
        return;
      }
      setState(() {});
      if (widget.translate) unawaited(_translateVisibleNames());
    } catch (e) {
      if (!mounted ||
          !_translationController.failBulkTranslation(generation)) {
        return;
      }
      _log.captureOutput('[FileExplorer] 名称翻译失败: $e');
      setState(() {});
    }
  }

  String _getDisplayName(String originalName) {
    return _translationController.displayName(
      originalName,
      showTranslation: widget.translate,
    );
  }
  // 处理文件点击
  void _handleFileTap(dynamic file, String title, String parentPath) {
    switch (_tapResolver.resolve(file)) {
      case FileExplorerTapAction.video:
        _playVideoWithSystemPlayer(file);
        return;
      case FileExplorerTapAction.audio:
        _playAudioFile(file, parentPath);
        return;
      case FileExplorerTapAction.image:
        _previewImageFile(file);
        return;
      case FileExplorerTapAction.pdf:
        _previewPdfFile(file);
        return;
      case FileExplorerTapAction.text:
        _previewTextFile(file);
        return;
      case FileExplorerTapAction.unsupported:
        SnackBarUtil.showInfo(
          context,
          S.of(context).unsupportedFileTypeWithTitle(title),
          duration: const Duration(seconds: 2),
        );
    }
  }
}
