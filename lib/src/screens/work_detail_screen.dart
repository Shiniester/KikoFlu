import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/snackbar_util.dart';
import '../../l10n/app_localizations.dart';

import '../models/work.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/scrollable_appbar.dart';
import '../services/work_track_file_builder.dart';
import '../services/storage_service.dart';
import '../services/cache_service.dart';
import '../services/remote_asset_cache.dart';
import '../utils/system_ui_style.dart';
import '../widgets/file_explorer_widget.dart';
import '../widgets/file_selection_dialog.dart';
import '../widgets/app_bottom_dock_transition.dart';
import '../widgets/global_audio_player_wrapper.dart';
import '../widgets/responsive_dialog.dart';
import '../widgets/work_bookmark_manager.dart';
import '../widgets/rating_detail_popup.dart';
import '../services/translation_service.dart';
import '../widgets/download_fab.dart';
import '../providers/work_detail_display_provider.dart';
import '../widgets/work_detail/tag_vote_dialog.dart';
import '../widgets/work_detail/add_tag_dialog.dart';
import '../widgets/work_detail/recommendation_section.dart';
import '../widgets/work_detail/work_title_header.dart';
import '../widgets/work_detail/work_metadata_sections.dart';
import '../widgets/work_detail/work_stats_section.dart';
import '../widgets/work_detail/work_extra_sections.dart';
import '../widgets/work_detail/work_cover_frame.dart';
import '../widgets/work_detail/work_detail_responsive_layout.dart';
import '../widgets/work_detail/work_detail_error_banner.dart';
import '../widgets/work_detail/work_progress_action_button.dart';
import '../widgets/work_detail_route_readiness.dart';

import '../widgets/work_image_reader.dart';

final workDetailCoverCacheProvider = Provider(
  (ref) => CacheService.imageCacheManager,
);

class WorkDetailScreen extends ConsumerStatefulWidget {
  final Work work;
  final ImageProvider<Object>? initialCoverImageProvider;

  const WorkDetailScreen({
    super.key,
    required this.work,
    this.initialCoverImageProvider,
  });

  @override
  ConsumerState<WorkDetailScreen> createState() => _WorkDetailScreenState();
}

class _WorkDetailScreenState extends ConsumerState<WorkDetailScreen> {
  Work? _detailedWork;
  final _metadataChanges = ValueNotifier(0);
  final _initialContentReady = ValueNotifier(false);
  final _deferredContentReady = ValueNotifier(false);
  final _routeReadiness = WorkDetailRouteReadiness();
  bool _initialLoadStarted = false;
  bool _deferredContentScheduled = false;
  bool _translationChoiceMade = false;
  int _metadataLoadGeneration = 0;
  Work get _currentWork => _detailedWork ?? widget.work;
  String? _errorMessage;
  final _hdImageProvider = ValueNotifier<ImageProvider?>(null);
  String? _currentProgress; // 当前收藏状态
  int? _currentRating; // 当前评分
  bool _isUpdatingProgress = false; // 是否正在更新状态
  bool _isOpeningFileSelection = false; // iOS上防止快速重复点击造成对话框立即关闭
  bool _isOpeningProgressDialog = false; // 防止标记状态对话框重复快速打开
  final FileExplorerController _fileExplorerController =
      FileExplorerController();
  RemoteAssetLease? _hdPreloadLease;
  Animation<double>? _routeAnimation;
  ImageStream? _hdDecodeStream;
  ImageStreamListener? _hdDecodeListener;
  ImageProvider? _hdDecodingProvider;
  Completer<bool>? _hdDecodeCompletion;
  int _hdGeneration = 0;
  bool _hdScheduled = false;
  bool _hdAttempted = false;
  final _showDetailCover = ValueNotifier(false);
  Size? _hdPixelSize;

  Size get _coverPixelSize {
    final media = MediaQuery.of(context);
    final landscape = media.orientation == Orientation.landscape;
    return Size(
      ((media.size.width * (landscape ? 0.4 : 1) - 16) * media.devicePixelRatio)
          .ceilToDouble()
          .clamp(1, double.infinity),
      ((landscape ? media.size.height * 0.8 : 500) * media.devicePixelRatio)
          .ceilToDouble()
          .clamp(1, double.infinity),
    );
  }

  ImageProvider _sizedCover(ImageProvider provider) {
    final size = _coverPixelSize;
    return ResizeImage(
      provider,
      width: size.width.toInt(),
      height: size.height.toInt(),
      policy: ResizeImagePolicy.fit,
    );
  }

  // 翻译相关状态
  String? _translatedTitle; // 翻译后的标题
  bool _showTranslation = false; // 是否显示翻译
  bool _isTranslating = false; // 是否正在翻译

  @override
  void initState() {
    super.initState();
    // 初始化收藏状态（从传入的work中获取）
    _currentProgress = widget.work.progress;
    _currentRating = widget.work.userRating;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = _coverPixelSize;
    if (_hdPixelSize != null && _hdPixelSize != size) {
      _cancelHDImage();
      _hdImageProvider.value = null;
    }
    _hdPixelSize = size;
    _routeReadiness.bind(
      route: ModalRoute.of(context),
      navigator: Navigator.maybeOf(context),
    );
    final animation = ModalRoute.of(context)?.animation;
    if (_routeAnimation != animation) {
      _routeAnimation?.removeStatusListener(_onRouteStatus);
      _routeAnimation?.removeListener(_onRouteFrame);
      _routeAnimation = animation;
      animation?.addStatusListener(_onRouteStatus);
      animation?.addListener(_onRouteFrame);
    }
    if (!_initialLoadStarted) {
      _initialLoadStarted = true;
      unawaited(_loadWorkDetail());
    }
    _scheduleDeferredContent();
    _scheduleHDImage();
  }

  void _onRouteFrame() {
    if (_routeAnimation!.value < 1 &&
        (_hdPreloadLease != null || _hdDecodeStream != null)) {
      _cancelHDImage();
    }
  }

  void _onRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse ||
        status == AnimationStatus.dismissed) {
      _cancelHDImage();
    } else if (status == AnimationStatus.completed) {
      _scheduleHDImage();
    }
  }

  void _scheduleDeferredContent() {
    if (_deferredContentScheduled || _deferredContentReady.value) return;
    _deferredContentScheduled = true;
    unawaited(_showDeferredContentWhenIdle());
  }

  void _onInitialContentReady() {
    if (_initialContentReady.value) return;
    unawaited(_publishInitialContentReadyWhenIdle());
  }

  Future<void> _publishInitialContentReadyWhenIdle() async {
    final ready = await _routeReadiness.waitForIdle();
    if (!mounted || !ready || _initialContentReady.value) return;
    _initialContentReady.value = true;
  }

  Future<void> _showDeferredContentWhenIdle() async {
    final autoTranslateFuture = ref
        .read(autoTranslateWorkDetailsProvider.notifier)
        .resolvedEnabled();
    final ready = await _routeReadiness.waitForIdle();
    if (!mounted || !ready) return;
    _deferredContentReady.value = true;
    _scheduleHDImage();

    final autoTranslate = await autoTranslateFuture;
    if (!mounted) return;
    if (!_routeReadiness.isIdle) {
      final idle = await _routeReadiness.waitForIdle();
      if (!mounted || !idle) return;
    }
    if (autoTranslate && !_translationChoiceMade) {
      _setTranslationEnabled(true);
    }
  }

  void _scheduleHDImage() {
    if (!_deferredContentReady.value ||
        _hdAttempted ||
        _hdScheduled ||
        _hdImageProvider.value != null) {
      return;
    }
    _hdScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hdScheduled = false;
      if (!mounted || !_deferredContentReady.value) return;
      unawaited(_preloadHDImageWhenIdle());
    });
  }

  Future<void> _preloadHDImageWhenIdle() async {
    await Future<void>.delayed(Duration.zero);
    if (!_routeReadiness.isIdle && !await _routeReadiness.waitForIdle()) {
      return;
    }
    if (!mounted ||
        !_deferredContentReady.value ||
        _hdAttempted ||
        _hdImageProvider.value != null) {
      return;
    }
    _hdAttempted = true;
    await _preloadHDImage();
  }

  void _cancelDecode() {
    final stream = _hdDecodeStream;
    final listener = _hdDecodeListener;
    if (stream != null && listener != null) stream.removeListener(listener);
    final completion = _hdDecodeCompletion;
    if (completion != null && !completion.isCompleted) {
      completion.complete(false);
    }
    final provider = _hdDecodingProvider;
    if (provider != null) unawaited(provider.evict());
    _hdDecodeStream = null;
    _hdDecodeListener = null;
    _hdDecodeCompletion = null;
    _hdDecodingProvider = null;
  }

  void _cancelHDImage() {
    _hdGeneration++;
    _hdAttempted = false;
    _cancelDecode();
    final lease = _hdPreloadLease;
    _hdPreloadLease = null;
    if (lease != null) unawaited(lease.release());
  }

  Future<bool> _decodeHDImage(ImageProvider provider) {
    final completion = Completer<bool>();
    final stream = provider.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    void detach() {
      stream.removeListener(listener);
      if (identical(_hdDecodeStream, stream)) {
        _hdDecodeStream = null;
        _hdDecodeListener = null;
        _hdDecodeCompletion = null;
        _hdDecodingProvider = null;
      }
    }

    listener = ImageStreamListener(
      (image, _) {
        image.dispose();
        detach();
        if (!completion.isCompleted) completion.complete(true);
      },
      onError: (Object error, StackTrace? stack) {
        detach();
        if (!completion.isCompleted) completion.completeError(error, stack);
      },
    );
    _hdDecodeStream = stream;
    _hdDecodeListener = listener;
    _hdDecodeCompletion = completion;
    _hdDecodingProvider = provider;
    stream.addListener(listener);
    return completion.future;
  }

  @override
  void dispose() {
    _metadataChanges.dispose();
    _initialContentReady.dispose();
    _deferredContentReady.dispose();
    _showDetailCover.dispose();
    _hdImageProvider.dispose();
    _routeReadiness.dispose();
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _routeAnimation?.removeListener(_onRouteFrame);
    _cancelHDImage();
    super.dispose();
  }

  // 预加载高清图片，完全加载后再切换；取消或未完成时返回 false。
  Future<bool> _preloadHDImage({
    bool forceRevalidate = false,
    bool speculative = true,
    bool reportFailure = false,
  }) async {
    final generation = ++_hdGeneration;
    _cancelDecode();
    bool active() => mounted && generation == _hdGeneration;
    final authState = ref.read(authProvider);
    final host = authState.host ?? '';
    final token = authState.token ?? '';

    if (host.isEmpty) return true;

    final imageUrl = widget.work.getCoverImageUrl(host, token: token);
    final previousLease = _hdPreloadLease;
    if (forceRevalidate && previousLease != null) {
      _hdPreloadLease = null;
      await previousLease.release();
    }
    if (!active()) return false;
    final lease = ref
        .read(workDetailCoverCacheProvider)
        .acquireFile(
          imageUrl,
          key: 'work_cover_${widget.work.id}',
          headers: StorageService.serverCookieHeaders,
          speculative: speculative,
          forceRevalidate: forceRevalidate,
        );
    _hdPreloadLease = lease;
    if (!forceRevalidate && previousLease != null) {
      await previousLease.release();
    }

    try {
      final file = await lease.file;
      if (!await _routeReadiness.waitForIdle() || !active()) return false;
      final imageProvider = _sizedCover(FileImage(File(file.path)));
      if (forceRevalidate) await imageProvider.evict();
      if (!await _routeReadiness.waitForIdle() || !active()) return false;
      final decoded = await _decodeHDImage(imageProvider);
      if (!decoded || !await _routeReadiness.waitForIdle() || !active()) {
        return false;
      }
      _hdImageProvider.value = imageProvider;
      return true;
    } catch (e) {
      // 预加载失败，保持使用缓存图片
      if (await _routeReadiness.waitForIdle() && active()) {
        _showDetailCoverFallback();
        debugPrint('HD image preload failed: $e');
        if (reportFailure) rethrow;
      }
      return false;
    } finally {
      if (identical(_hdPreloadLease, lease)) _hdPreloadLease = null;
      await lease.release();
    }
  }

  void _showDetailCoverFallback() {
    if (!_showDetailCover.value) {
      _showDetailCover.value = true;
    }
  }

  void _toggleTranslation() {
    _translationChoiceMade = true;
    _setTranslationEnabled(!_showTranslation);
  }

  void _setTranslationEnabled(bool enabled) {
    if (_showTranslation == enabled) return;
    final translateTitle =
        enabled && _translatedTitle == null && !_isTranslating;
    setState(() {
      _showTranslation = enabled;
      if (translateTitle) _isTranslating = true;
    });
    if (translateTitle) unawaited(_translateTitle());
  }

  Future<void> _translateTitle() async {
    final work = _detailedWork ?? widget.work;
    try {
      final translationService = TranslationService();
      final translated = await translationService.translate(
        work.title,
        sourceLang: 'ja',
      );

      if (mounted) {
        setState(() {
          _translatedTitle = translated;
          _isTranslating = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isTranslating = false;
        });

        SnackBarUtil.showError(
          context,
          S.of(context).translationFailed(e.toString()),
          duration: const Duration(seconds: 2),
        );
      }
    }
  }

  // 复制文本到剪贴板并显示提示
  Future<void> _copyToClipboard(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      SnackBarUtil.showSuccess(
        context,
        S.of(context).copiedToClipboard(label, text),
        duration: const Duration(seconds: 2),
      );
    }
  }

  // 显示标签投票信息
  void _showTagInfo(Tag tag) {
    showDialog(
      context: context,
      builder: (context) => TagVoteDialog(
        tag: tag,
        workId: widget.work.id,
        onVoteChanged: (updatedTag) {
          // 投票成功后更新本地状态
          if (mounted) {
            setState(() {
              // 更新 _detailedWork 中的 tag
              if (_detailedWork != null && _detailedWork!.tags != null) {
                final tagIndex = _detailedWork!.tags!.indexWhere(
                  (t) => t.id == updatedTag.id,
                );
                if (tagIndex != -1) {
                  final updatedTags = List<Tag>.from(_detailedWork!.tags!);
                  updatedTags[tagIndex] = updatedTag;
                  _detailedWork = _detailedWork!.copyWith(tags: updatedTags);
                }
              }
            });
          }
        },
        onCopyTag: () => _copyToClipboard(tag.name, S.of(context).tagLabel),
      ),
    );
  }

  // 显示添加标签对话框
  void _showAddTagDialog() {
    showDialog(
      context: context,
      builder: (context) => AddTagDialog(
        workId: widget.work.id,
        existingTags: _detailedWork?.tags ?? widget.work.tags ?? [],
        onTagsAdded: () {
          // 添加成功后刷新作品详情
          _loadWorkDetail();
        },
      ),
    );
  }

  // 在外部浏览器打开原始链接
  Future<void> _openSourceUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      // 直接尝试在外部浏览器打开，不依赖 canLaunchUrl 检查
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (!launched && mounted) {
        // 如果外部应用模式失败，尝试平台默认方式
        final fallbackLaunched = await launchUrl(
          uri,
          mode: LaunchMode.platformDefault,
        );

        if (!fallbackLaunched && mounted) {
          SnackBarUtil.showWarning(
            context,
            S.of(context).cannotOpenLink,
            duration: const Duration(seconds: 2),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        SnackBarUtil.showError(
          context,
          S.of(context).openLinkFailed(e.toString()),
          duration: const Duration(seconds: 2),
        );
      }
    }
  }

  // 显示文件选择对话框
  Future<void> _showFileSelectionDialog() async {
    // 防抖: 避免 iOS 上快速双击导致同一路由被重复创建又立即被关闭
    if (_isOpeningFileSelection) return;
    setState(() => _isOpeningFileSelection = true);

    final preparedWorkFuture = _prepareWorkForFileSelection();

    try {
      await showResponsiveBottomSheet<void>(
        context: context,
        maxHeight: MediaQuery.of(context).size.height * 0.9,
        builder: (dialogContext) {
          return FutureBuilder<Work>(
            future: preparedWorkFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(S.of(context).loadingFileList),
                      ],
                    ),
                  ),
                );
              }

              if (snapshot.hasError) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    BottomSheetHeader(title: S.of(context).loadFailed),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        S
                            .of(context)
                            .loadFileListFailed(snapshot.error.toString()),
                      ),
                    ),
                  ],
                );
              }

              final work = snapshot.data!;
              return FileSelectionDialog(work: work);
            },
          );
        },
      );
    } finally {
      if (mounted) setState(() => _isOpeningFileSelection = false);
    }
  }

  Future<Work> _prepareWorkForFileSelection() async {
    final apiService = ref.read(kikoeruApiServiceProvider);
    final files = await apiService.getWorkTracks(widget.work.id);
    final authState = ref.read(authProvider);
    final trackFileBuilder = WorkTrackFileBuilder(
      host: authState.host ?? '',
      token: authState.token ?? '',
    );
    final baseWork = _detailedWork ?? widget.work;
    return trackFileBuilder.withTracks(work: baseWork, files: files);
  }

  void _updateMetadata(VoidCallback update) {
    update();
    _metadataChanges.value++;
  }

  Future<void> _loadWorkDetail() async {
    final generation = ++_metadataLoadGeneration;
    try {
      if (!await _routeReadiness.waitForIdle() ||
          !mounted ||
          generation != _metadataLoadGeneration) {
        return;
      }
      _updateMetadata(() {
        _errorMessage = null;
      });

      final apiService = ref.read(kikoeruApiServiceProvider);
      final response = await apiService.getWork(widget.work.id);
      if (!await _routeReadiness.waitForIdle() ||
          !mounted ||
          generation != _metadataLoadGeneration) {
        return;
      }
      final detailedWork = _workFromDetailResponse(response);

      _updateMetadata(() {
        _detailedWork = detailedWork;
        // 更新收藏状态（从API响应中获取最新状态）
        _currentProgress = detailedWork.progress;
        _currentRating = detailedWork.userRating;
      });
    } catch (e) {
      if (await _routeReadiness.waitForIdle() &&
          mounted &&
          generation == _metadataLoadGeneration) {
        _updateMetadata(() {
          _errorMessage = S.of(context).loadFailedWithError(e.toString());
        });
      }
    }
  }

  // 下拉刷新：强制从网络获取最新数据
  Future<void> _refreshWorkDetail() async {
    final generation = ++_metadataLoadGeneration;
    try {
      if (!await _routeReadiness.waitForIdle() ||
          !mounted ||
          generation != _metadataLoadGeneration) {
        return;
      }
      if (!_deferredContentReady.value) {
        _deferredContentReady.value = true;
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!await _routeReadiness.waitForIdle() ||
          !mounted ||
          generation != _metadataLoadGeneration) {
        return;
      }
      if (!_fileExplorerController.isAttached) {
        _deferredContentReady.value = true;
        await WidgetsBinding.instance.endOfFrame;
        if (!await _routeReadiness.waitForIdle() ||
            !mounted ||
            generation != _metadataLoadGeneration) {
          return;
        }
      }
      if (!_fileExplorerController.isAttached) {
        throw StateError('Work file list is not attached');
      }
      _updateMetadata(() {
        _errorMessage = null;
      });
      _hdAttempted = true;

      final apiService = ref.read(kikoeruApiServiceProvider);

      // 元数据、文件树和封面都必须完成验证后再报告刷新成功。
      final refreshResults = await Future.wait<dynamic>([
        apiService.getWork(widget.work.id, forceRefresh: true),
        _fileExplorerController.refresh(forceRefresh: true),
        _preloadHDImage(
          forceRevalidate: true,
          speculative: false,
          reportFailure: true,
        ),
      ]);
      if (!mounted || generation != _metadataLoadGeneration) return;
      if (!await _routeReadiness.waitForIdle() ||
          !mounted ||
          generation != _metadataLoadGeneration) {
        return;
      }
      if (refreshResults.last != true) {
        throw StateError('Cover refresh cancelled');
      }
      final response = refreshResults.first as Map<String, dynamic>;
      final detailedWork = _workFromDetailResponse(response);

      if (mounted && generation == _metadataLoadGeneration) {
        _updateMetadata(() {
          _detailedWork = detailedWork;
          _currentProgress = detailedWork.progress;
          _currentRating = detailedWork.userRating;
        });

        // 显示刷新成功提示
        SnackBarUtil.showSuccess(
          context,
          S.of(context).refreshComplete,
          duration: const Duration(seconds: 1),
        );
      }
    } catch (e) {
      if (await _routeReadiness.waitForIdle() &&
          mounted &&
          generation == _metadataLoadGeneration) {
        _updateMetadata(() {
          _errorMessage = S.of(context).refreshFailed(e.toString());
        });

        SnackBarUtil.showError(
          context,
          S.of(context).refreshFailed(e.toString()),
          duration: const Duration(seconds: 2),
        );
      }
    }
  }

  Work _workFromDetailResponse(Map<String, dynamic> response) {
    final currentWork = _currentWork;
    final responseWork = Work.fromJson(response);
    final hasLanguageMetadata =
        response.containsKey('lang') ||
        response.containsKey('translation_info') ||
        response.containsKey('language_editions');
    return responseWork.copyWith(
      circleId: response.containsKey('circle_id') ? null : currentWork.circleId,
      name: response.containsKey('name') ? null : currentWork.name,
      vas: response.containsKey('vas') ? null : currentWork.vas,
      tags: response.containsKey('tags') ? null : currentWork.tags,
      release: response.containsKey('release') ? null : currentWork.release,
      lang: hasLanguageMetadata ? responseWork.lang : currentWork.lang,
      otherLanguageEditions:
          response.containsKey('other_language_editions_in_db')
          ? null
          : currentWork.otherLanguageEditions,
    );
  }

  // 显示收藏状态选择对话框
  Future<void> _showProgressDialog() async {
    if (_isOpeningProgressDialog) return; // 防抖避免 iOS 双击导致立即关闭
    setState(() => _isOpeningProgressDialog = true);

    final manager = WorkBookmarkManager(ref: ref, context: context);

    try {
      await manager.showMarkDialog(
        workId: widget.work.id,
        currentProgress: _currentProgress,
        currentRating: _currentRating,
        workTitle: widget.work.title,
        onChanged: (newProgress, newRating) {
          // 更新本地状态
          if (mounted) {
            setState(() {
              _currentProgress = newProgress;
              _currentRating = newRating;
              _isUpdatingProgress = false;
            });
          }
        },
      );
    } finally {
      if (mounted) setState(() => _isOpeningProgressDialog = false);
    }
  }

  // 显示评分详情弹窗
  Future<void> _showRatingDetailDialog(Work work) async {
    if (work.rateCountDetail == null || work.rateCountDetail!.isEmpty) return;
    if (work.rateAverage == null || work.rateCount == null) return;

    await showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: RatingDetailPopup(
          ratingDetails: work.rateCountDetail!,
          averageRating: work.rateAverage!,
          totalCount: work.rateCount!,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 根据主题亮度设置状态栏图标颜色
    final brightness = Theme.of(context).brightness;
    final systemOverlayStyle = transparentSystemBarsForBrightness(brightness);

    return GlobalAudioPlayerWrapper.workDetails(
      child: Scaffold(
        floatingActionButton: const DownloadFab(),
        appBar: ScrollableAppBar(
          systemOverlayStyle: systemOverlayStyle,
          // 作品编号作为标题,支持长按复制
          title: GestureDetector(
            onLongPress: () => _copyToClipboard(
              widget.work.displayId,
              S.of(context).workIdLabel,
            ),
            child: Text(
              widget.work.displayId,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            // 下载按钮
            IconButton(
              icon: const Icon(Icons.download),
              onPressed: _showFileSelectionDialog,
              tooltip: S.of(context).download,
            ),
            ListenableBuilder(
              listenable: _metadataChanges,
              builder: (context, _) => WorkProgressActionButton(
                progress: _currentProgress,
                isLoading: _isUpdatingProgress,
                onPressed: _showProgressDialog,
              ),
            ),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final authState = ref.watch(authProvider);
    final host = authState.host ?? '';
    final token = authState.token ?? '';

    // 使用已有的work信息（来自列表），详细信息加载后再更新
    final work = _detailedWork ?? widget.work;

    // 封面图片组件
    final coverUrl = work.getCoverImageUrl(host, token: token);
    final displaySettings = ref.watch(workDetailDisplayProvider);

    // 信息内容组件
    final infoWidget = SliverPadding(
      padding: const EdgeInsets.all(16),
      sliver: SliverMainAxisGroup(
        slivers: [
          ListenableBuilder(
            listenable: _metadataChanges,
            builder: (context, _) => _buildMetadata(_currentWork),
          ),
          // 文件浏览器组件 - 移除固定高度，让它自由展开
          ValueListenableBuilder<bool>(
            valueListenable: _deferredContentReady,
            builder: (context, ready, _) => ready
                ? FileExplorerWidget(
                    work: widget.work,
                    currentWork: () => _currentWork,
                    onInitialContentReady: _onInitialContentReady,
                    controller: _fileExplorerController,
                    initialLoadReady: _routeReadiness.waitForIdle,
                    translate: _showTranslation,
                  )
                : const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),

          // 相关推荐
          ListenableBuilder(
            listenable: Listenable.merge([
              _metadataChanges,
              _initialContentReady,
            ]),
            builder: (context, _) => _initialContentReady.value
                ? RecommendationSection(work: _currentWork)
                : const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),
        ],
      ),
    );

    return WorkDetailResponsiveLayout(
      onRefresh: _refreshWorkDetail,
      coverBuilder: (context, isLandscape) {
        return ListenableBuilder(
          listenable: _metadataChanges,
          builder: (context, _) => WorkCoverFrame(
            isLandscape: isLandscape,
            showSubtitleBadge:
                displaySettings.showSubtitleTag &&
                _currentWork.hasSubtitle == true,
            showAgeRating: displaySettings.showAgeRating,
            age: _currentWork.age,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => WorkImageReader(
                    title: _currentWork.title,
                    images: [
                      {
                        'url': coverUrl,
                        'title': _currentWork.title,
                        'hash': '',
                        'cacheKey': 'work_cover_${widget.work.id}',
                      },
                    ],
                    initialIndex: 0,
                  ),
                ),
              );
            },
            layers: [
              ValueListenableBuilder<bool>(
                valueListenable: _showDetailCover,
                builder: (context, showDetailCover, _) =>
                    ValueListenableBuilder<ImageProvider?>(
                      valueListenable: _hdImageProvider,
                      builder: (context, hdImageProvider, _) {
                        final imageProvider =
                            hdImageProvider ??
                            (showDetailCover
                                ? _sizedCover(
                                    CachedNetworkImageProvider(
                                      coverUrl,
                                      cacheKey: 'work_cover_${widget.work.id}',
                                    ),
                                  )
                                : widget.initialCoverImageProvider);
                        if (imageProvider == null) {
                          return _buildCoverPlaceholder();
                        }
                        return Image(
                          image: imageProvider,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          frameBuilder: (context, child, frame, _) =>
                              frame == null &&
                                  !identical(
                                    imageProvider,
                                    widget.initialCoverImageProvider,
                                  )
                              ? _buildCoverPlaceholder()
                              : child,
                          errorBuilder: (context, error, stack) =>
                              _buildCoverPlaceholder(),
                        );
                      },
                    ),
              ),
            ],
          ),
        );
      },
      infoSliver: infoWidget,
    );
  }

  Widget _buildMetadata(Work work) {
    return SliverList.list(
      addSemanticIndexes: false,
      children: [
        // 标题（可长按复制）+ 内联字幕图标（紧跟标题最后一个字，不换行）
        Consumer(
          builder: (context, ref, _) {
            final displaySettings = ref.watch(workDetailDisplayProvider);
            return WorkTitleHeader(
              title: work.title,
              translatedTitle: _translatedTitle,
              showTranslation: _showTranslation,
              showTranslateButton: displaySettings.showTranslateButton,
              isTranslating: _isTranslating,
              showExternalLink:
                  displaySettings.showExternalLinks && work.sourceUrl != null,
              onTranslate: _toggleTranslation,
              onOpenExternalLink: work.sourceUrl == null
                  ? null
                  : () => _openSourceUrl(work.sourceUrl!),
              onCopy: (title) =>
                  _copyToClipboard(title, S.of(context).titleLabel),
            );
          },
        ),
        const SizedBox(height: 8),
        WorkDetailErrorBanner(message: _errorMessage, onRetry: _loadWorkDetail),
        // 评分信息、价格、时长和销量
        Consumer(
          builder: (context, ref, _) {
            final displaySettings = ref.watch(workDetailDisplayProvider);
            return WorkStatsSection(
              work: work,
              currentRating: _currentRating,
              showRating: displaySettings.showRating,
              showPrice: displaySettings.showPrice,
              showDuration: displaySettings.showDuration,
              showSales: displaySettings.showSales,
              onShowRatingDetails: () => _showRatingDetailDialog(work),
              onShowProgress: _showProgressDialog,
            );
          },
        ),
        const SizedBox(height: 16),
        WorkCreatorChipsSection(work: work, onCopy: _copyToClipboard),
        WorkTagChipsSection(
          tags: work.tags,
          onTagLongPress: _showTagInfo,
          onTagSecondaryTap: _showTagInfo,
          onAddTag: _showAddTagDialog,
        ),
        Consumer(
          builder: (context, ref, _) {
            final displaySettings = ref.watch(workDetailDisplayProvider);
            return WorkReleaseDateSection(
              release: work.release,
              visible: displaySettings.showReleaseDate,
            );
          },
        ),
        Builder(
          builder: (context) => OtherLanguageEditionsSection(
            editions: work.otherLanguageEditions,
            onEditionSelected: (edition) {
              pushWorkDetailRoute(
                context,
                builder: (context) => WorkDetailScreen(
                  work: Work(id: edition.id, title: edition.title),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCoverPlaceholder() {
    final initialCover = widget.initialCoverImageProvider;
    if (initialCover != null) {
      return Image(
        image: initialCover,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) =>
            _buildMissingCoverPlaceholder(),
      );
    }
    return _buildMissingCoverPlaceholder();
  }

  Widget _buildMissingCoverPlaceholder() {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: 300,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.image_not_supported,
        size: 64,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }
}
