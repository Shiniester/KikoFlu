import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/app_navigation_scope.dart';
import '../widgets/tab_page_motion.dart';
import 'audio_screen.dart';
import '../comics/ui/comic_screen.dart';
import '../videos/ui/video_screen.dart';
import 'settings_screen.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  late final PageController _pages;
  final _pagesKey = GlobalKey();
  final _selection = ValueNotifier<int?>(0);
  final PageStorageBucket _bucket = PageStorageBucket();
  AppNavigationController? _navigation;
  bool _reduceMotion = false;
  int _currentIndex = 0;
  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _screens = [
      const AudioScreen(key: PageStorageKey('audio_screen')),
      ValueListenableBuilder<int?>(
        valueListenable: _selection,
        builder: (context, index, child) => ComicScreen(
          key: const PageStorageKey('comic_screen'),
          active: index == 1,
        ),
      ),
      ValueListenableBuilder<int?>(
        valueListenable: _selection,
        builder: (context, index, child) => VideoScreen(
          key: const PageStorageKey('video_screen'),
          active: index == 2,
        ),
      ),
      const SettingsScreen(key: PageStorageKey('settings_screen')),
    ];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final navigation = AppNavigationScope.of(context);
    final index = navigation.selectedIndex;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_navigation == null) {
      _currentIndex = index;
      _selection.value = index;
      _pages = PageController(initialPage: index);
    } else if (_currentIndex != index) {
      _currentIndex = index;
      _selection.value = index;
      moveToTabPage(_pages, index, reduceMotion: reduceMotion);
    }
    if (reduceMotion && !_reduceMotion && _pages.hasClients) {
      _pages.jumpToPage(_currentIndex);
    }
    _navigation = navigation;
    _reduceMotion = reduceMotion;
  }

  @override
  void dispose() {
    _pages.dispose();
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageStorage(
    bucket: _bucket,
    child: TabPageWarmup(
      key: _pagesKey,
      pages: _pages,
      target: _selection,
      builder: (cacheExtent) => PageView(
        key: const ValueKey('main-tab-pages'),
        controller: _pages,
        physics: const NeverScrollableScrollPhysics(),
        allowImplicitScrolling: cacheExtent > 0,
        scrollCacheExtent: ScrollCacheExtent.viewport(cacheExtent),
        children: [
          for (var i = 0; i < _screens.length; i++)
            LazyTabPage(
              key: ValueKey(i),
              index: i,
              target: _selection,
              pages: _pages,
              child: ValueListenableBuilder<int?>(
                valueListenable: _selection,
                child: _screens[i],
                builder: (context, index, child) =>
                    HeroMode(enabled: index == i, child: child!),
              ),
            ),
        ],
      ),
    ),
  );
}
