import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../../l10n/app_localizations.dart';
import '../../providers/audio_provider.dart';
import '../../services/storage_service.dart';
import '../../services/log_service.dart';
import '../../widgets/mini_player.dart';
import '../comic_models.dart';
import '../comic_providers.dart';
import '../comic_library.dart';

import 'comic_widgets.dart';
import 'comic_settings_screen.dart';

bool isComicSpread(ComicReadingMode mode) =>
    mode == ComicReadingMode.spread || mode == ComicReadingMode.reverseSpread;
int comicViewIndex(int page, ComicReadingMode mode) =>
    isComicSpread(mode) ? page ~/ 2 : page;
int comicPageIndex(int view, ComicReadingMode mode) =>
    isComicSpread(mode) ? view * 2 : view;

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
  Object? _error;
  int _generation = 0;
  int _layoutGeneration = 0;
  PageController? _pager;
  ItemScrollController _continuous = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  final Map<int, Future<Uint8List>> _images = {};
  final Map<int, double> _aspectRatios = {};
  Timer? _saveTimer;
  @override
  void initState() {
    super.initState();
    _active = ref.read(comicReaderActiveProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
    _positions.itemPositions.addListener(_scrolled);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _active.state = true;
        _setBars();
      }
    });
    _loadChapter();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _saveTimer?.cancel();
    if (_pages.isNotEmpty) {
      unawaited(_saveProgress(_chapter.id, _page));
    }
    _positions.itemPositions.removeListener(_scrolled);
    _pager?.dispose();
    _focus.dispose();
    Future.microtask(() {
      if (_active.mounted) _active.state = false;
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _pages.isNotEmpty) {
      _saveTimer?.cancel();
      unawaited(_saveProgress(_chapter.id, _page));
    }
  }

  void _setBars() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _toggle() {
    setState(() => _controls = !_controls);
  }

  Future<void> _loadChapter() async {
    final generation = ++_generation;
    _saveTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _images.clear();
      _aspectRatios.clear();
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
        setState(() {
          _error = e;
          _loading = false;
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
          _aspectRatios[page] = descriptor.width / descriptor.height;
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
    for (var i = _page; i <= _page + count && i < _pages.length; i++) {
      _image(i).then<void>((_) {}, onError: (Object _, StackTrace __) {});
    }
    _images.removeWhere((i, _) => i < _page - 2 || i > _page + count + 2);
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
        ref.read(comicReadingModeProvider) != ComicReadingMode.continuous) {
      return;
    }
    final visible =
        _positions.itemPositions.value
            .where((p) => p.itemTrailingEdge > 0.05 && p.itemLeadingEdge < 1)
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
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

  void _step(int delta) {
    if (_loading) return;
    final mode = ref.read(comicReadingModeProvider);
    final target = _page + delta * (isComicSpread(mode) ? 2 : 1);
    if (target >= _pages.length) {
      _chapterBy(1);
    } else if (target < 0) {
      _chapterBy(-1);
    } else {
      _jump(target);
    }
  }

  Widget _pageImage(int page, {bool continuous = false}) =>
      FutureBuilder<Uint8List>(
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
            content = _ZoomableComicPage(
              child: Image.memory(
                snapshot.data!,
                fit: BoxFit.contain,
                width: continuous ? MediaQuery.sizeOf(context).width : null,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.broken_image, color: Colors.white),
              ),
            );
          }
          // Keep decoded page geometry after its image bytes leave the cache.
          // Returning to an earlier page must not resize the slivers above it.
          return continuous
              ? AspectRatio(
                  aspectRatio: _aspectRatios[page] ?? 2 / 3,
                  child: content,
                )
              : content;
        },
      );
  Widget _body(ComicReadingMode mode) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ComicErrorView(error: _error!, retry: _loadChapter);
    }
    if (mode == ComicReadingMode.continuous) {
      return ScrollablePositionedList.builder(
        key: ValueKey(_layoutGeneration),
        padding: EdgeInsets.zero,
        itemCount: _pages.length,
        itemScrollController: _continuous,
        itemPositionsListener: _positions,
        initialScrollIndex: _page,
        itemBuilder: (context, i) => GestureDetector(
          onTap: _toggle,
          child: _pageImage(i, continuous: true),
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
            return Row(
              children: [
                for (final page
                    in mode == ComicReadingMode.reverseSpread
                        ? indices.reversed
                        : indices)
                  Expanded(child: _pageImage(page)),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(comicReadingModeProvider);
    ref.listen(comicReadingModeProvider, (_, __) {
      if (mounted) setState(_resetLayout);
    });
    final s = S.of(context);
    final hasAudio = ref.watch(currentTrackProvider).valueOrNull != null;
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
            if (_controls || _error != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
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
                        PopupMenuButton<ComicReadingMode>(
                          tooltip: s.comicReadingMode,
                          icon: const Icon(Icons.chrome_reader_mode),
                          itemBuilder: (_) => ComicReadingMode.values
                              .map(
                                (m) => PopupMenuItem(
                                  value: m,
                                  child: Text(comicModeLabel(s, m)),
                                ),
                              )
                              .toList(),
                          onSelected: (m) {
                            ref.read(comicReadingModeProvider.notifier).state =
                                m;
                            StorageService.setString(
                              'comic_reading_mode',
                              m.name,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_controls && _pages.isNotEmpty)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              tooltip: s.comicPreviousChapter,
                              onPressed: () => _chapterBy(-1),
                              icon: const Icon(Icons.skip_previous),
                            ),
                            Expanded(
                              child: Slider(
                                value: _page.toDouble(),
                                min: 0,
                                max: (_pages.length - 1)
                                    .clamp(1, 1 << 30)
                                    .toDouble(),
                                onChanged: _pages.length < 2
                                    ? null
                                    : (value) => _jump(value.round()),
                              ),
                            ),
                            Text('${_page + 1}/${_pages.length}'),
                            IconButton(
                              tooltip: s.comicNextChapter,
                              onPressed: () => _chapterBy(1),
                              icon: const Icon(Icons.skip_next),
                            ),
                          ],
                        ),
                        if (hasAudio) const MiniPlayer(),
                      ],
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
  const _ZoomableComicPage({required this.child});
  final Widget child;
  @override
  State<_ZoomableComicPage> createState() => _ZoomableComicPageState();
}

class _ZoomableComicPageState extends State<_ZoomableComicPage> {
  final _transform = TransformationController();
  bool _zoomed = false;

  void _updateZoom() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1;
    if (_zoomed != zoomed) setState(() => _zoomed = zoomed);
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onDoubleTap: !(StorageService.getBool('comic_double_tap_zoom') ?? true)
        ? null
        : () {
            _transform.value = _transform.value.getMaxScaleOnAxis() > 1
                ? Matrix4.identity()
                : (Matrix4.identity()..scaleByDouble(2, 2, 1, 1));
            _updateZoom();
          },
    child: InteractiveViewer(
      transformationController: _transform,
      panEnabled: _zoomed,
      onInteractionUpdate: (_) => _updateZoom(),
      minScale: 1,
      maxScale: 5,
      child: Center(child: widget.child),
    ),
  );
}
