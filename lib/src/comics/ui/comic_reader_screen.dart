import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../../l10n/app_localizations.dart';
import '../../providers/audio_provider.dart';
import '../../services/storage_service.dart';
import '../../services/log_service.dart';
import '../../widgets/mini_player.dart';
import '../../utils/snackbar_util.dart';
import '../comic_models.dart';
import '../comic_providers.dart';
import '../comic_library.dart';

import 'comic_widgets.dart';
import 'comic_settings_screen.dart';
import 'comic_page_preview.dart';
import 'comic_reader_menu_button.dart';
import 'comic_actions.dart';

bool isComicSpread(ComicReadingMode mode) =>
    mode == ComicReadingMode.spread || mode == ComicReadingMode.reverseSpread;
int comicViewIndex(int page, ComicReadingMode mode) =>
    isComicSpread(mode) ? page ~/ 2 : page;
int comicPageIndex(int view, ComicReadingMode mode) =>
    isComicSpread(mode) ? view * 2 : view;
int _pageAfterView(int page, int delta, ComicReadingMode mode) =>
    comicPageIndex(comicViewIndex(page, mode) + delta, mode);

class ComicReaderScreen extends ConsumerStatefulWidget {
  const ComicReaderScreen({
    super.key,
    required this.comic,
    required this.chapter,
    this.initialPage = 0,
  });
  final Comic comic;
  final ComicChapter chapter;
  final int initialPage;
  @override
  ConsumerState<ComicReaderScreen> createState() => _ComicReaderScreenState();
}

class _ComicReaderScreenState extends ConsumerState<ComicReaderScreen>
    with WidgetsBindingObserver {
  late ComicChapter _chapter = widget.chapter;
  late int _page = widget.initialPage;
  late final ComicLibrary _library = ref.read(comicLibraryProvider);
  late final StateController<bool> _active;
  List<ComicPage> _pages = [];
  bool _controls = false, _loading = true;
  bool _savingFavorite = false, _choosingDownload = false;
  Object? _error;
  int _generation = 0;
  int _layoutGeneration = 0;
  PageController? _pager;
  ItemScrollController _continuous = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  final Map<int, Future<Uint8List>> _images = {};
  final Map<int, Size> _imageSizes = {};
  Matrix4 _continuousTransform = Matrix4.identity();
  ScrollPosition? _continuousPosition;
  bool _continuousPinching = false;
  Timer? _saveTimer;
  Timer? _autoPageTimer;
  bool _autoPageTurning = false;
  bool _appResumed = true;
  bool _routeIsCurrent = true;
  Animation<double>? _routeAnimation;
  AnimationStatusListener? _routeStatusListener;
  bool _immersiveBarsRequested = false;
  bool _orientationRequested = false;
  Size _viewport = Size.zero;
  @override
  void initState() {
    super.initState();
    _active = ref.read(comicReaderActiveProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
    _positions.itemPositions.addListener(_scrolled);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _active.state = true;
      }
    });
    _loadChapter();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (!_routeIsCurrent) _stopAutoPageTurn(rebuild: false);
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _routeAnimation)) return;
    if (_routeAnimation != null && _routeStatusListener != null) {
      _routeAnimation!.removeStatusListener(_routeStatusListener!);
    }
    _routeAnimation = animation;
    if (animation == null) return;
    _routeStatusListener = (status) {
      if (status == AnimationStatus.completed) {
        _setBarsAfterFrame(animation);
      }
    };
    animation.addStatusListener(_routeStatusListener!);
    if (animation.status == AnimationStatus.completed) {
      _setBarsAfterFrame(animation);
    }
  }

  void _setBarsAfterFrame(Animation<double> animation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !identical(animation, _routeAnimation) ||
          animation.status != AnimationStatus.completed) {
        return;
      }
      _setBars();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _saveTimer?.cancel();
    _autoPageTimer?.cancel();
    _autoPageTimer = null;
    _autoPageTurning = false;
    if (_pages.isNotEmpty) {
      unawaited(_saveProgress(_chapter.id, _page));
    }
    _positions.itemPositions.removeListener(_scrolled);
    if (_routeAnimation != null && _routeStatusListener != null) {
      _routeAnimation!.removeStatusListener(_routeStatusListener!);
    }
    _pager?.dispose();
    _focus.dispose();
    Future.microtask(() {
      if (_active.mounted) _active.state = false;
    });
    // Keep the native window layout unchanged until the reader is removed.
    _restoreBars();
    if (_orientationRequested) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    if (!_appResumed) _stopAutoPageTurn();
    if (state != AppLifecycleState.resumed && _pages.isNotEmpty) {
      _saveTimer?.cancel();
      unawaited(_saveProgress(_chapter.id, _page));
    }
  }

  void _setBars() {
    _immersiveBarsRequested = true;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _setOrientation(ref.read(comicScreenOrientationProvider));
  }

  void _setOrientation(ComicScreenOrientation orientation) {
    _orientationRequested = true;
    SystemChrome.setPreferredOrientations(switch (orientation) {
      ComicScreenOrientation.system => DeviceOrientation.values,
      ComicScreenOrientation.portrait => [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ],
      ComicScreenOrientation.landscape => [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
    });
  }

  void _restoreBars() {
    if (!_immersiveBarsRequested) return;
    _immersiveBarsRequested = false;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _toggle() {
    setState(() => _controls = !_controls);
  }

  void _toggleAutoPageTurn() {
    if (_autoPageTurning) {
      _stopAutoPageTurn();
      return;
    }
    if (_loading ||
        _error != null ||
        _pages.isEmpty ||
        !_appResumed ||
        !_routeIsCurrent) {
      return;
    }
    final interval = (StorageService.getInt('comic_auto_page_interval') ?? 5)
        .clamp(1, 20)
        .toInt();
    _autoPageTimer = Timer.periodic(Duration(seconds: interval), (_) {
      _autoPageTick();
    });
    setState(() => _autoPageTurning = true);
  }

  void _stopAutoPageTurn({bool rebuild = true}) {
    _autoPageTimer?.cancel();
    _autoPageTimer = null;
    if (!_autoPageTurning) return;
    if (rebuild && mounted) {
      setState(() => _autoPageTurning = false);
    } else {
      _autoPageTurning = false;
    }
  }

  bool _hasNextChapter() {
    final chapterIndex = widget.comic.chapters.indexWhere(
      (chapter) => chapter.id == _chapter.id,
    );
    return chapterIndex >= 0 && chapterIndex + 1 < widget.comic.chapters.length;
  }

  bool _continuousAtEnd() {
    final position = _continuousPosition;
    if (position == null ||
        !position.hasContentDimensions ||
        position.pixels < position.maxScrollExtent - 1) {
      return false;
    }
    final lastPage = _pages.length - 1;
    final lastItem = _positions.itemPositions.value
        .where((item) => item.index == lastPage)
        .firstOrNull;
    if (lastItem == null || _viewport.height <= 0) return false;
    final scale = _continuousTransform.getMaxScaleOnAxis();
    final translation = _continuousTransform.getTranslation();
    final visibleBottom =
        ((_viewport.height - translation.y) / scale / _viewport.height).clamp(
          0.0,
          1.0,
        );
    return lastItem.itemTrailingEdge <= visibleBottom + .01;
  }

  void _autoPageTick() {
    if (!_autoPageTurning || !mounted) return;
    if (!_appResumed || !_routeIsCurrent) {
      _stopAutoPageTurn();
      return;
    }
    if (_loading) return;
    if (_error != null || _pages.isEmpty) {
      _stopAutoPageTurn();
      return;
    }
    final mode = ref.read(comicReadingModeProvider);
    if (mode == ComicReadingMode.continuous) {
      if (_continuousAtEnd()) {
        if (_hasNextChapter()) {
          unawaited(_chapterBy(1));
        } else {
          _stopAutoPageTurn();
        }
        return;
      }
      final position = _continuousPosition;
      if (position == null || !position.hasContentDimensions) return;
      final target = (position.pixels + 600)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if (target != position.pixels) position.jumpTo(target);
      return;
    }
    final nextPage = _pageAfterView(_page, 1, mode);
    if (nextPage >= _pages.length) {
      if (_hasNextChapter()) {
        unawaited(_chapterBy(1));
      } else {
        _stopAutoPageTurn();
      }
      return;
    }
    _step(1);
  }

  Widget _controlLayer({
    required Key key,
    required bool visible,
    required Offset hiddenOffset,
    required Widget child,
  }) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 300);
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeFocus(
        excluding: !visible,
        child: ExcludeSemantics(
          excluding: !visible,
          child: AnimatedSlide(
            key: key,
            offset: visible ? Offset.zero : hiddenOffset,
            duration: duration,
            curve: Curves.ease,
            child: child,
          ),
        ),
      ),
    );
  }

  Future<void> _loadChapter() async {
    final generation = ++_generation;
    _saveTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _images.clear();
      _imageSizes.clear();
      _pages = [];
    });
    try {
      final offline = await ref
          .read(comicDownloadsProvider)
          .offlinePages(widget.comic, _chapter);
      final source = ref
          .read(comicSourcesProvider)
          .firstWhere((s) => s.key == widget.comic.source);
      final pages = offline ?? await source.pages(widget.comic, _chapter);
      if (pages.isEmpty) {
        throw const ComicSourceException('This chapter has no pages.');
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _pages = pages;
        _page = _page.clamp(0, pages.length - 1);
        _loading = false;
        _resetLayout();
      });
      _record();
      _preload();
    } catch (e) {
      if (mounted && generation == _generation) {
        _autoPageTimer?.cancel();
        _autoPageTimer = null;
        setState(() {
          _error = e;
          _loading = false;
          _autoPageTurning = false;
        });
      }
    }
  }

  void _resetLayout() {
    final old = _pager;
    _pager = PageController(
      initialPage: comicViewIndex(_page, ref.read(comicReadingModeProvider)),
    );
    _continuous = ItemScrollController();
    _continuousTransform = Matrix4.identity();
    _continuousPosition = null;
    _continuousPinching = false;
    _layoutGeneration++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      old?.dispose();
    });
  }

  Future<Uint8List> _image(int page) => _images.putIfAbsent(page, () async {
    final generation = _generation;
    final source = ref
        .read(comicSourcesProvider)
        .firstWhere((s) => s.key == widget.comic.source);
    final bytes = await ref.read(comicImageLoaderProvider)(
      source,
      _pages[page],
    );
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        if (mounted && generation == _generation) {
          _imageSizes[page] = Size(
            descriptor.width.toDouble(),
            descriptor.height.toDouble(),
          );
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
    return bytes;
  });
  void _preload() {
    final count = StorageService.getInt('comic_preload') ?? 3;
    final first =
        ref.read(comicReadingModeProvider) == ComicReadingMode.continuous
        ? (_page - count).clamp(0, _pages.length - 1)
        : _page;
    for (var i = first; i <= _page + count && i < _pages.length; i++) {
      _image(i).then<void>((_) {}, onError: (Object _, StackTrace __) {});
    }
    _images.removeWhere((i, _) => i < first - 2 || i > _page + count + 2);
  }

  Future<void> _saveProgress(String chapter, int page) async {
    try {
      await _library.saveProgress(widget.comic, chapter, page);
    } catch (error) {
      LogService.instance.error('Comic progress: $error', tag: 'Comics');
    }
  }

  void _record() {
    _saveTimer?.cancel();
    final chapter = _chapter.id;
    final page = _page;
    _saveTimer = Timer(
      const Duration(milliseconds: 200),
      () => _saveProgress(chapter, page),
    );
  }

  void _changed(int page) {
    page = page.clamp(0, _pages.length - 1);
    if (page == _page) return;
    setState(() => _page = page);
    _record();
    _preload();
  }

  void _scrolled() {
    if (!mounted ||
        _pages.isEmpty ||
        _viewport.height <= 0 ||
        ref.read(comicReadingModeProvider) != ComicReadingMode.continuous) {
      return;
    }
    final scale = _continuousTransform.getMaxScaleOnAxis();
    final translation = _continuousTransform.getTranslation();
    final visibleTop = ((-translation.y / scale) / _viewport.height).clamp(
      0.0,
      1.0,
    );
    final visibleBottom =
        ((_viewport.height - translation.y) / scale / _viewport.height).clamp(
          0.0,
          1.0,
        );
    final visibleThreshold = visibleTop + 0.05 * (visibleBottom - visibleTop);
    final visible =
        _positions.itemPositions.value
            .where(
              (p) =>
                  p.itemTrailingEdge > visibleThreshold &&
                  p.itemLeadingEdge < visibleBottom,
            )
            .toList()
          ..sort((a, b) {
            final aVisibleTop = math.max(a.itemLeadingEdge, visibleTop);
            final bVisibleTop = math.max(b.itemLeadingEdge, visibleTop);
            return aVisibleTop.compareTo(bVisibleTop);
          });
    if (visible.isNotEmpty) _changed(visible.first.index);
  }

  void _jump(int page) {
    if (_pages.isEmpty || _loading) return;
    page = page.clamp(0, _pages.length - 1);
    final mode = ref.read(comicReadingModeProvider);
    if (mode == ComicReadingMode.continuous) {
      if (_continuous.isAttached) _continuous.jumpTo(index: page);
    } else {
      if (_pager?.hasClients ?? false) {
        _pager!.jumpToPage(comicViewIndex(page, mode));
      }
    }
    _changed(page);
  }

  Future<void> _chapterBy(int delta) async {
    if (_loading) return;
    final index =
        widget.comic.chapters.indexWhere((c) => c.id == _chapter.id) + delta;
    if (index < 0 || index >= widget.comic.chapters.length) return;
    _saveTimer?.cancel();
    setState(() => _loading = true);
    if (_pages.isNotEmpty) {
      await _saveProgress(_chapter.id, _page);
    }
    if (!mounted) return;
    _chapter = widget.comic.chapters[index];
    _page = 0;
    await _loadChapter();
  }

  Future<void> _chooseChapter() async {
    final chapters = widget.comic.chapters;
    final current = chapters.indexWhere((chapter) => chapter.id == _chapter.id);
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(S.of(dialogContext).comicChooseChapters),
        content: SizedBox(
          width: 420,
          height: 340,
          child: ListView.builder(
            itemCount: chapters.length,
            itemBuilder: (context, index) => ListTile(
              title: Text(chapters[index].title),
              selected: index == current,
              trailing: index == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(dialogContext, index),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(S.of(dialogContext).cancel),
          ),
        ],
      ),
    );
    if (!mounted || selected == null || selected == current) return;
    await _chapterBy(selected - current);
  }

  Future<void> _favorite() async {
    if (_savingFavorite) return;
    setState(() => _savingFavorite = true);
    try {
      await saveComicFavorite(ref, widget.comic);
      if (mounted) SnackBarUtil.showSuccess(context, S.of(context).comicSaved);
    } catch (error) {
      if (mounted) SnackBarUtil.showError(context, error.toString());
    } finally {
      if (mounted) setState(() => _savingFavorite = false);
    }
  }

  Future<void> _download() async {
    if (_choosingDownload) return;
    setState(() => _choosingDownload = true);
    try {
      await downloadComicChapters(
        context,
        ref,
        widget.comic,
        initialChapterId: _chapter.id,
      );
    } finally {
      if (mounted) setState(() => _choosingDownload = false);
    }
  }

  Future<Uint8List> _previewImage(int page) async {
    final generation = _generation;
    final image = _image(page);
    try {
      final bytes = await image;
      if (mounted && generation == _generation) _preload();
      return bytes;
    } catch (_) {
      if (generation == _generation && identical(_images[page], image)) {
        _images.remove(page);
      }
      rethrow;
    }
  }

  Future<void> _showPagePreview() async {
    final generation = _generation;
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .7,
        minChildSize: .35,
        maxChildSize: .95,
        builder: (context, controller) => ComicPagePreview(
          pageCount: _pages.length,
          initialPage: _page,
          title: _chapter.title,
          scrollController: controller,
          loadImage: _previewImage,
          onSelected: (page) => Navigator.pop(sheetContext, page),
        ),
      ),
    );
    if (!mounted || generation != _generation || selected == null) return;
    _jump(selected);
    setState(() {
      _controls = true;
      _resetLayout();
    });
  }

  void _step(int delta) {
    if (_loading) return;
    final mode = ref.read(comicReadingModeProvider);
    final target = _pageAfterView(_page, delta, mode);
    if (target >= _pages.length) {
      _chapterBy(1);
    } else if (target < 0) {
      _chapterBy(-1);
    } else {
      _jump(target);
    }
  }

  Widget _pageImage(int page, {bool continuous = false, bool zoomable = true}) {
    return FutureBuilder<Uint8List>(
      future: _image(page),
      builder: (context, snapshot) {
        Widget content;
        if (snapshot.hasError) {
          content = Center(
            child: IconButton(
              color: Colors.white,
              tooltip: S.of(context).retry,
              onPressed: () => setState(() => _images.remove(page)),
              icon: const Icon(Icons.refresh),
            ),
          );
        } else if (!snapshot.hasData) {
          content = const Center(child: CircularProgressIndicator());
        } else {
          content = Image.memory(
            snapshot.data!,
            fit: BoxFit.contain,
            width: continuous
                ? MediaQuery.sizeOf(context).width
                : double.infinity,
            height: continuous ? null : double.infinity,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.broken_image, color: Colors.white),
          );
          if (!continuous && zoomable) {
            content = _ZoomableComicPage(
              key: ValueKey('comic-page-zoom-$page'),
              imageSize: _imageSizes[page],
              child: content,
            );
          }
        }
        // Keep decoded page geometry after its image bytes leave the cache.
        // Returning to an earlier page must not resize the slivers above it.
        return continuous
            ? AspectRatio(
                aspectRatio: _imageSizes[page]?.aspectRatio ?? 2 / 3,
                child: content,
              )
            : content;
      },
    );
  }

  Widget _continuousPage(int page) => AnimatedSize(
    key: ValueKey('comic-page-size-$page'),
    alignment: Alignment.topCenter,
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 250),
    curve: Curves.easeOutCubic,
    child: _pageImage(page, continuous: true),
  );

  Widget _body(ComicReadingMode mode) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ComicErrorView(error: _error!, retry: _loadChapter);
    }
    if (mode == ComicReadingMode.continuous) {
      final layoutGeneration = _layoutGeneration;
      return KeyedSubtree(
        key: ValueKey('comic-continuous-layout-$_layoutGeneration'),
        child: _ZoomableComicPage(
          key: const ValueKey('comic-continuous-zoom'),
          focalZoom: true,
          continuous: true,
          onTransformChanged: (value) {
            if (!mounted || layoutGeneration != _layoutGeneration) return;
            _continuousTransform = value.clone();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && layoutGeneration == _layoutGeneration) {
                _scrolled();
              }
            });
          },
          onPinchChanged: (pinching) {
            if (mounted &&
                layoutGeneration == _layoutGeneration &&
                _continuousPinching != pinching) {
              setState(() => _continuousPinching = pinching);
            }
          },
          canPanVertically: (dy) {
            final positions = _positions.itemPositions.value;
            if (dy > 0) {
              return positions.any(
                (position) =>
                    position.index == 0 && position.itemLeadingEdge >= 0,
              );
            }
            return positions.any(
              (position) =>
                  position.index == _pages.length - 1 &&
                  position.itemTrailingEdge <= 1,
            );
          },
          child: SizedBox.expand(
            child: ScrollablePositionedList.builder(
              key: ValueKey(_layoutGeneration),
              padding: EdgeInsets.zero,
              physics: _continuousPinching
                  ? const NeverScrollableScrollPhysics()
                  : const BouncingScrollPhysics(),
              itemCount: _pages.length,
              itemScrollController: _continuous,
              itemPositionsListener: _positions,
              initialScrollIndex: _page,
              itemBuilder: (context, i) => Builder(
                builder: (itemContext) {
                  _continuousPosition = Scrollable.of(itemContext).position;
                  return GestureDetector(
                    onTap: _toggle,
                    child: _continuousPage(i),
                  );
                },
              ),
            ),
          ),
        ),
      );
    }
    final spread = isComicSpread(mode);
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: (details) {
          final fraction = details.localPosition.dx / constraints.maxWidth;
          if (!(StorageService.getBool('comic_tap_to_turn') ?? true) ||
              (fraction > .28 && fraction < .72)) {
            _toggle();
          } else {
            final reverse =
                mode == ComicReadingMode.rightToLeft ||
                mode == ComicReadingMode.reverseSpread;
            _step((fraction < .28 ? -1 : 1) * (reverse ? -1 : 1));
          }
        },
        child: PageView.builder(
          key: ValueKey(_layoutGeneration),
          controller: _pager,
          scrollDirection: mode == ComicReadingMode.vertical
              ? Axis.vertical
              : Axis.horizontal,
          reverse:
              mode == ComicReadingMode.rightToLeft ||
              mode == ComicReadingMode.reverseSpread,
          itemCount: spread ? (_pages.length + 1) ~/ 2 : _pages.length,
          onPageChanged: (i) => _changed(comicPageIndex(i, mode)),
          itemBuilder: (context, i) {
            if (!spread) return _pageImage(i);
            final indices = [i * 2, if (i * 2 + 1 < _pages.length) i * 2 + 1];
            return _ZoomableComicPage(
              key: ValueKey('comic-spread-zoom-$i'),
              focalZoom: true,
              child: Row(
                children: [
                  for (final page
                      in mode == ComicReadingMode.reverseSpread
                          ? indices.reversed
                          : indices)
                    Expanded(child: _pageImage(page, zoomable: false)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(comicSettingsRevisionProvider);
    final mode = ref.watch(comicReadingModeProvider);
    final orientation = ref.watch(comicScreenOrientationProvider);
    ref.listen(comicReadingModeProvider, (_, __) {
      if (mounted) setState(_resetLayout);
    });
    ref.listen(
      comicScreenOrientationProvider,
      (_, next) => _setOrientation(next),
    );
    final hasAudio = ref.watch(currentTrackProvider).valueOrNull != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        return _buildReader(context, mode, orientation, hasAudio);
      },
    );
  }

  Widget _buildReader(
    BuildContext context,
    ComicReadingMode mode,
    ComicScreenOrientation orientation,
    bool hasAudio,
  ) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: KeyboardListener(
        autofocus: true,
        focusNode: _focus,
        onKeyEvent: (event) {
          if (event is! KeyDownEvent) return;
          final reverse =
              mode == ComicReadingMode.rightToLeft ||
              mode == ComicReadingMode.reverseSpread;
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _step(reverse ? -1 : 1);
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _step(reverse ? 1 : -1);
          }
          if (event.logicalKey == LogicalKeyboardKey.pageDown ||
              event.logicalKey == LogicalKeyboardKey.arrowDown) {
            _step(1);
          }
          if (event.logicalKey == LogicalKeyboardKey.pageUp ||
              event.logicalKey == LogicalKeyboardKey.arrowUp) {
            _step(-1);
          }
          if (event.logicalKey == LogicalKeyboardKey.space) _toggle();
        },
        child: Stack(
          children: [
            Positioned.fill(child: _body(mode)),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _controlLayer(
                key: const ValueKey('comic-reader-top-controls'),
                visible: _controls || _error != null,
                hiddenOffset: const Offset(0, -1),
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: SafeArea(
                    bottom: false,
                    child: Row(
                      children: [
                        const BackButton(),
                        Expanded(
                          child: Text(
                            '${widget.comic.title}\n${_chapter.title}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          tooltip: s.comicReaderSettings,
                          icon: const Icon(Icons.more_vert),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const ComicReaderSettingsScreen(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_pages.isNotEmpty)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _controlLayer(
                  key: const ValueKey('comic-reader-bottom-controls'),
                  visible: _controls,
                  hiddenOffset: const Offset(0, 1),
                  child: Material(
                    color: Theme.of(context).colorScheme.surface,
                    child: SafeArea(
                      top: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 600),
                              child: LayoutBuilder(
                                builder: (context, constraints) => SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: SizedBox(
                                    width: math.max(constraints.maxWidth, 336),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Semantics(
                                            value:
                                                '${_page + 1}/${_pages.length}',
                                            child: IconButton(
                                              key: const ValueKey(
                                                'comic-page-preview',
                                              ),
                                              tooltip: s.preview,
                                              onPressed:
                                                  _loading || _error != null
                                                  ? null
                                                  : _showPagePreview,
                                              icon: const Icon(Icons.grid_view),
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: IconButton(
                                            tooltip: s.comicChooseChapters,
                                            onPressed:
                                                _loading ||
                                                    widget
                                                        .comic
                                                        .chapters
                                                        .isEmpty
                                                ? null
                                                : _chooseChapter,
                                            icon: const Icon(Icons.list),
                                          ),
                                        ),
                                        Expanded(
                                          child: IconButton(
                                            key: const ValueKey(
                                              'comic-auto-page-turn',
                                            ),
                                            tooltip: _autoPageTurning
                                                ? s.pause
                                                : s.comicAutoPageTurn,
                                            isSelected: _autoPageTurning,
                                            style: IconButton.styleFrom(
                                              backgroundColor: _autoPageTurning
                                                  ? Theme.of(context)
                                                        .colorScheme
                                                        .secondaryContainer
                                                  : null,
                                            ),
                                            icon: const Icon(
                                              Icons.timer_outlined,
                                            ),
                                            selectedIcon: const Icon(
                                              Icons.pause,
                                            ),
                                            onPressed:
                                                _loading || _error != null
                                                ? null
                                                : _toggleAutoPageTurn,
                                          ),
                                        ),
                                        Expanded(
                                          child:
                                              ComicReaderMenuButton<
                                                ComicReadingMode
                                              >(
                                                tooltip: s.comicReadingMode,
                                                icon: const Icon(
                                                  Icons.chrome_reader_mode,
                                                ),
                                                itemBuilder: (_) => ComicReadingMode
                                                    .values
                                                    .map(
                                                      (m) =>
                                                          CheckedPopupMenuItem(
                                                            value: m,
                                                            checked: m == mode,
                                                            child: Text(
                                                              comicModeLabel(
                                                                s,
                                                                m,
                                                              ),
                                                            ),
                                                          ),
                                                    )
                                                    .toList(),
                                                onSelected: (m) {
                                                  ref
                                                          .read(
                                                            comicReadingModeProvider
                                                                .notifier,
                                                          )
                                                          .state =
                                                      m;
                                                  StorageService.setString(
                                                    'comic_reading_mode',
                                                    m.name,
                                                  );
                                                },
                                              ),
                                        ),
                                        Expanded(
                                          child: Semantics(
                                            value: comicOrientationLabel(
                                              s,
                                              orientation,
                                            ),
                                            child:
                                                ComicReaderMenuButton<
                                                  ComicScreenOrientation
                                                >(
                                                  tooltip:
                                                      s.comicScreenOrientation,
                                                  icon: Icon(switch (orientation) {
                                                    ComicScreenOrientation
                                                        .system =>
                                                      Icons.screen_rotation,
                                                    ComicScreenOrientation
                                                        .portrait =>
                                                      Icons
                                                          .screen_lock_portrait,
                                                    ComicScreenOrientation
                                                        .landscape =>
                                                      Icons
                                                          .screen_lock_landscape,
                                                  }),
                                                  itemBuilder: (_) => [
                                                    for (final orientation
                                                        in ComicScreenOrientation
                                                            .values)
                                                      CheckedPopupMenuItem(
                                                        value: orientation,
                                                        checked:
                                                            orientation ==
                                                            ref.read(
                                                              comicScreenOrientationProvider,
                                                            ),
                                                        child: Text(
                                                          comicOrientationLabel(
                                                            s,
                                                            orientation,
                                                          ),
                                                        ),
                                                      ),
                                                  ],
                                                  onSelected: (orientation) {
                                                    ref
                                                            .read(
                                                              comicScreenOrientationProvider
                                                                  .notifier,
                                                            )
                                                            .state =
                                                        orientation;
                                                    StorageService.setString(
                                                      'comic_screen_orientation',
                                                      orientation.name,
                                                    );
                                                  },
                                                ),
                                          ),
                                        ),
                                        Expanded(
                                          child: IconButton(
                                            tooltip: s.comicFavorites,
                                            icon: const Icon(
                                              Icons.bookmark_add_outlined,
                                            ),
                                            onPressed: _savingFavorite
                                                ? null
                                                : _favorite,
                                          ),
                                        ),
                                        Expanded(
                                          child: IconButton(
                                            tooltip: s.download,
                                            icon: const Icon(Icons.download),
                                            onPressed:
                                                _loading ||
                                                    _choosingDownload ||
                                                    widget
                                                        .comic
                                                        .chapters
                                                        .isEmpty
                                                ? null
                                                : _download,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (hasAudio) const MiniPlayer(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  final _focus = FocusNode();
}

class _ZoomableComicPage extends StatefulWidget {
  const _ZoomableComicPage({
    super.key,
    required this.child,
    this.imageSize,
    this.focalZoom = false,
    this.continuous = false,
    this.onTransformChanged,
    this.onPinchChanged,
    this.canPanVertically,
  });

  final Widget child;
  final Size? imageSize;
  final bool focalZoom;
  final bool continuous;
  final ValueChanged<Matrix4>? onTransformChanged;
  final ValueChanged<bool>? onPinchChanged;
  final bool Function(double dy)? canPanVertically;

  @override
  State<_ZoomableComicPage> createState() => _ZoomableComicPageState();
}

class _ZoomableComicPageState extends State<_ZoomableComicPage>
    with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _zoomAnimationController;
  Matrix4Tween? _zoomTween;
  Size _viewportSize = Size.zero;
  bool _constrainingTransform = false;
  Offset? _doubleTapPosition;
  final Map<int, Offset> _continuousPointers = {};
  double? _pinchStartDistance;
  double? _pinchStartScale;
  Offset? _pinchStartFocal;
  Offset? _pinchScenePoint;
  Offset? _panZoomStartFocal;
  double? _panZoomStartScale;
  Offset? _panZoomScenePoint;
  bool _panZoomPinching = false;
  bool _zoomed = false;
  double _gestureStartScale = 1;
  int _scaleState = 0;
  int? _targetScaleState;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_constrainTransform);
    _zoomAnimationController =
        AnimationController(vsync: this, lowerBound: 0, upperBound: 1)
          ..addListener(_applyZoomAnimation)
          ..addStatusListener(_zoomAnimationStatusChanged);
  }

  @override
  void dispose() {
    _zoomAnimationController
      ..removeListener(_applyZoomAnimation)
      ..removeStatusListener(_zoomAnimationStatusChanged)
      ..dispose();
    _transform.removeListener(_constrainTransform);
    _transform.dispose();
    super.dispose();
  }

  List<double> _scaleTargets(Size viewport) {
    if (widget.focalZoom) return const [1, 1.75];
    final image = widget.imageSize;
    if (image == null || viewport.isEmpty || image.isEmpty) {
      return const [1, 1.75, 1];
    }
    final contained = math.min(
      viewport.width / image.width,
      viewport.height / image.height,
    );
    final covering = math.max(
      viewport.width / image.width,
      viewport.height / image.height,
    );
    return [1, covering / contained, 1 / contained];
  }

  Matrix4 _matrixAt(
    Size viewport,
    double scale,
    Offset scenePoint, {
    Offset? focalPoint,
  }) {
    final center = focalPoint ?? viewport.center(Offset.zero);
    final extentX = viewport.width * (1 - scale);
    final extentY = viewport.height * (1 - scale);
    final dx = (center.dx - scenePoint.dx * scale)
        .clamp(math.min(0.0, extentX), math.max(0.0, extentX))
        .toDouble();
    final dy = (center.dy - scenePoint.dy * scale)
        .clamp(math.min(0.0, extentY), math.max(0.0, extentY))
        .toDouble();
    return Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  void _constrainTransform() {
    final viewport = _viewportSize;
    if (widget.continuous || viewport.isEmpty || _constrainingTransform) {
      return;
    }
    final scale = _transform.value.getMaxScaleOnAxis();
    final bounded = _matrixAt(
      viewport,
      scale,
      _transform.toScene(viewport.center(Offset.zero)),
    );
    final translation = _transform.value.getTranslation();
    final boundedTranslation = bounded.getTranslation();
    if ((translation.x - boundedTranslation.x).abs() < .001 &&
        (translation.y - boundedTranslation.y).abs() < .001) {
      return;
    }
    _constrainingTransform = true;
    _transform.value = bounded;
    _constrainingTransform = false;
  }

  void _transformChanged() {
    _updateZoomed();
    if (widget.continuous) {
      widget.onTransformChanged?.call(_transform.value);
    }
  }

  void _beginContinuousPinch() {
    final pointers = _continuousPointers.values.take(2).toList();
    if (pointers.length != 2) return;
    _pinchStartFocal = (pointers[0] + pointers[1]) / 2;
    _pinchStartDistance = (pointers[0] - pointers[1]).distance;
    _pinchStartScale = _transform.value.getMaxScaleOnAxis();
    _pinchScenePoint = _transform.toScene(_pinchStartFocal!);
    widget.onPinchChanged?.call(true);
  }

  void _continuousPointerDown(PointerDownEvent event) {
    _interruptZoomAnimation(keepTarget: true);
    final previousCount = _continuousPointers.length;
    _continuousPointers[event.pointer] = event.localPosition;
    if (previousCount < 2 && _continuousPointers.length >= 2) {
      if (_targetScaleState != null) {
        _targetScaleState = null;
        _scaleState = -1;
      }
      _beginContinuousPinch();
    }
  }

  bool _continuousVerticalPanAllowed(double dy) {
    if (dy == 0) return false;
    return widget.canPanVertically?.call(dy) ?? false;
  }

  void _applyContinuousPan(Offset delta, Size viewport) {
    final scale = _transform.value.getMaxScaleOnAxis();
    if (scale <= 1.01) return;
    final translation = _transform.value.getTranslation();
    final dx = (translation.x + delta.dx)
        .clamp(viewport.width * (1 - scale), 0.0)
        .toDouble();
    final allowVertical = _continuousVerticalPanAllowed(delta.dy);
    final dy = allowVertical
        ? (translation.y + delta.dy)
              .clamp(viewport.height * (1 - scale), 0.0)
              .toDouble()
        : translation.y;
    if (dx == translation.x && dy == translation.y) return;
    _transform.value = _transform.value.clone()..setTranslationRaw(dx, dy, 0);
    _transformChanged();
  }

  void _applyContinuousScale(
    Size viewport,
    double scale,
    Offset scenePoint,
    Offset focalPoint,
  ) {
    final targetScale = scale.clamp(1.0, 5.0).toDouble();
    _targetScaleState = null;
    _scaleState = -1;
    _transform.value = _matrixAt(
      viewport,
      targetScale,
      scenePoint,
      focalPoint: focalPoint,
    );
    _transformChanged();
  }

  void _continuousPointerMove(PointerMoveEvent event, Size viewport) {
    final previous = _continuousPointers[event.pointer];
    if (previous == null) return;
    _continuousPointers[event.pointer] = event.localPosition;
    if (_targetScaleState != null) {
      _targetScaleState = null;
      _scaleState = -1;
    }
    if (_continuousPointers.length >= 2) {
      final pointers = _continuousPointers.values.take(2).toList();
      final initialDistance = _pinchStartDistance;
      final initialScale = _pinchStartScale;
      final scenePoint = _pinchScenePoint;
      if (initialDistance == null ||
          initialScale == null ||
          scenePoint == null ||
          initialDistance == 0) {
        return;
      }
      _applyContinuousScale(
        viewport,
        initialScale * (pointers[0] - pointers[1]).distance / initialDistance,
        scenePoint,
        (pointers[0] + pointers[1]) / 2,
      );
      return;
    }
    _applyContinuousPan(event.localPosition - previous, viewport);
  }

  void _continuousPointerRemoved(PointerEvent event) {
    final previousCount = _continuousPointers.length;
    _continuousPointers.remove(event.pointer);
    if (previousCount >= 2 && _continuousPointers.length < 2) {
      _pinchStartDistance = null;
      _pinchStartScale = null;
      _pinchStartFocal = null;
      _pinchScenePoint = null;
      widget.onPinchChanged?.call(false);
    }
  }

  void _panZoomStart(PointerPanZoomStartEvent event) {
    _interruptZoomAnimation(keepTarget: true);
    _panZoomStartFocal = event.localPosition;
    _panZoomStartScale = _transform.value.getMaxScaleOnAxis();
    _panZoomScenePoint = _transform.toScene(event.localPosition);
    _panZoomPinching = false;
  }

  void _panZoomUpdate(PointerPanZoomUpdateEvent event, Size viewport) {
    final startFocal = _panZoomStartFocal;
    final startScale = _panZoomStartScale;
    final scenePoint = _panZoomScenePoint;
    if (startFocal == null || startScale == null || scenePoint == null) return;
    final focalPoint = startFocal + event.localPan;
    if ((event.scale - 1).abs() > .01) {
      if (!_panZoomPinching) {
        _panZoomPinching = true;
        widget.onPinchChanged?.call(true);
      }
      if (_targetScaleState != null) {
        _targetScaleState = null;
        _scaleState = -1;
      }
      _applyContinuousScale(
        viewport,
        startScale * event.scale,
        scenePoint,
        focalPoint,
      );
    } else {
      _applyContinuousPan(event.localPanDelta, viewport);
    }
  }

  void _panZoomEnd(PointerPanZoomEndEvent event) {
    _panZoomStartFocal = null;
    _panZoomStartScale = null;
    _panZoomScenePoint = null;
    if (_panZoomPinching) {
      _panZoomPinching = false;
      widget.onPinchChanged?.call(false);
    }
  }

  void _updateZoomed() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (mounted && _zoomed != zoomed) setState(() => _zoomed = zoomed);
  }

  void _applyZoomAnimation() {
    final tween = _zoomTween;
    if (!mounted || tween == null) return;
    _transform.value = tween.transform(_zoomAnimationController.value);
    _transformChanged();
  }

  void _zoomAnimationStatusChanged(AnimationStatus status) {
    if ((status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) &&
        _targetScaleState != null) {
      if (status == AnimationStatus.completed && _zoomTween != null) {
        _transform.value = _zoomTween!.end!;
      }
      _scaleState = _targetScaleState!;
      _targetScaleState = null;
      _zoomTween = null;
      _transformChanged();
    }
  }

  void _interruptZoomAnimation({bool keepTarget = false}) {
    if (_zoomAnimationController.isAnimating) {
      _zoomAnimationController.stop();
    }
    _zoomTween = null;
    if (!keepTarget) _targetScaleState = null;
  }

  void _zoomToNextState(Size viewport) {
    final targets = _scaleTargets(viewport);
    final currentState = _targetScaleState ?? _scaleState;
    final currentScale = _transform.value.getMaxScaleOnAxis();
    final nextState = widget.focalZoom
        ? _targetScaleState != null
              ? 1 - _targetScaleState!
              : currentScale > 1.01
              ? 0
              : 1
        : currentState < 0
        ? 0
        : (currentState + 1) % targets.length;
    final center = viewport.center(Offset.zero);
    final focal = _doubleTapPosition == null
        ? center
        : Offset(
            _doubleTapPosition!.dx.clamp(0.0, viewport.width).toDouble(),
            _doubleTapPosition!.dy.clamp(0.0, viewport.height).toDouble(),
          );
    final scenePoint = widget.focalZoom ? _transform.toScene(focal) : center;
    final target = widget.focalZoom && nextState == 0
        ? Matrix4.identity()
        : _matrixAt(viewport, targets[nextState], scenePoint);
    _animateTo(target, nextState);
  }

  void _animateTo(Matrix4 target, int targetState) {
    _interruptZoomAnimation();
    final current = _transform.value.clone();
    if (MediaQuery.disableAnimationsOf(context)) {
      _transform.value = target;
      _scaleState = targetState;
      _targetScaleState = null;
      _transformChanged();
      return;
    }
    _zoomTween = Matrix4Tween(begin: current, end: target);
    _zoomAnimationController.value = 0;
    _targetScaleState = targetState;
    _zoomAnimationController.fling(velocity: .4);
  }

  void _interactionStarted() {
    final interruptedAnimation = _targetScaleState != null;
    _gestureStartScale = _transform.value.getMaxScaleOnAxis();
    _interruptZoomAnimation();
    if (interruptedAnimation) _scaleState = -1;
  }

  void _interactionUpdated(Size viewport) {
    final scale = _transform.value.getMaxScaleOnAxis();
    if ((scale - _gestureStartScale).abs() > .01) {
      _targetScaleState = null;
      _scaleState = -1;
    }
    if (!widget.focalZoom) {
      _transform.value = _matrixAt(
        viewport,
        scale,
        _transform.toScene(viewport.center(Offset.zero)),
      );
    }
    _updateZoomed();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MediaQuery.disableAnimationsOf(context) ||
        !_zoomAnimationController.isAnimating) {
      return;
    }
    final tween = _zoomTween;
    final targetState = _targetScaleState;
    if (tween != null && targetState != null) {
      _transform.value = tween.end!;
      _scaleState = targetState;
    }
    _interruptZoomAnimation();
    _transformChanged();
  }

  @override
  Widget build(BuildContext context) {
    final doubleTapEnabled =
        StorageService.getBool('comic_double_tap_zoom') ?? true;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        _viewportSize = viewport;
        final targets = _scaleTargets(viewport);
        if (widget.continuous) {
          return Listener(
            onPointerDown: _continuousPointerDown,
            onPointerMove: (event) => _continuousPointerMove(event, viewport),
            onPointerUp: _continuousPointerRemoved,
            onPointerCancel: _continuousPointerRemoved,
            onPointerPanZoomStart: _panZoomStart,
            onPointerPanZoomUpdate: (event) => _panZoomUpdate(event, viewport),
            onPointerPanZoomEnd: _panZoomEnd,
            child: GestureDetector(
              onDoubleTapDown: doubleTapEnabled
                  ? (details) => _doubleTapPosition = details.localPosition
                  : null,
              onDoubleTap: doubleTapEnabled
                  ? () => _zoomToNextState(viewport)
                  : null,
              child: ClipRect(
                child: AnimatedBuilder(
                  animation: _transform,
                  child: SizedBox.expand(child: Center(child: widget.child)),
                  builder: (context, child) => Transform(
                    key: const ValueKey('comic-reader-canvas-transform'),
                    alignment: Alignment.topLeft,
                    transform: _transform.value,
                    child: child,
                  ),
                ),
              ),
            ),
          );
        }
        final minimumScale = widget.focalZoom
            ? 1.0
            : targets.reduce((a, b) => a < b ? a : b);
        final minimumBoundaryScale = math.min(1.0, minimumScale);
        final boundaryMargin = widget.focalZoom
            ? EdgeInsets.zero
            : EdgeInsets.symmetric(
                horizontal: viewport.width * (1 / minimumBoundaryScale - 1) / 2,
                vertical: viewport.height * (1 / minimumBoundaryScale - 1) / 2,
              );
        return Listener(
          onPointerDown: (_) => _interruptZoomAnimation(keepTarget: true),
          child: GestureDetector(
            onDoubleTapDown: doubleTapEnabled
                ? (details) => _doubleTapPosition = details.localPosition
                : null,
            onDoubleTap: doubleTapEnabled
                ? () => _zoomToNextState(viewport)
                : null,
            child: InteractiveViewer(
              transformationController: _transform,
              boundaryMargin: boundaryMargin,
              panEnabled: _zoomed,
              panAxis: PanAxis.free,
              scaleEnabled: true,
              onInteractionStart: (_) => _interactionStarted(),
              onInteractionUpdate: (_) => _interactionUpdated(viewport),
              minScale: minimumScale,
              maxScale: widget.focalZoom
                  ? 5
                  : math
                        .max(5, targets.reduce((a, b) => a > b ? a : b))
                        .toDouble(),
              child: SizedBox.expand(child: Center(child: widget.child)),
            ),
          ),
        );
      },
    );
  }
}
