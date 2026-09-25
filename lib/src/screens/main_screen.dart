import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../providers/audio_provider.dart';
import '../providers/update_provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/app_bottom_dock_transition.dart';
import '../widgets/app_bottom_dock.dart';
import '../widgets/mini_player.dart';
import 'audio_screen.dart';
import '../comics/ui/comic_screen.dart';
import 'settings_screen.dart';
import '../providers/settings_provider.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen>
    with TickerProviderStateMixin {
  late TabController _tabs = TabController(length: 3, vsync: this);
  int _currentIndex = 0;
  final _selection = ValueNotifier(0);
  static const int _settingsTabIndex = 2;

  // 使用 PageStorageBucket 来保存页面状态
  final PageStorageBucket _bucket = PageStorageBucket();

  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _screens = const [
      AudioScreen(key: PageStorageKey('audio_screen')),
      ComicScreen(key: PageStorageKey('comic_screen')),
      SettingsScreen(key: PageStorageKey('settings_screen')),
    ];
  }

  @override
  void dispose() {
    _tabs.dispose();
    _selection.dispose();
    super.dispose();
  }

  Widget _buildPages() => TabBarView(
    key: const ValueKey('main-tab-pages'),
    controller: _tabs,
    physics: const NeverScrollableScrollPhysics(),
    children: [
      for (var i = 0; i < _screens.length; i++)
        _MainTabPage(
          key: ValueKey(i),
          index: i,
          selection: _selection,
          child: _screens[i],
        ),
    ],
  );

  List<NavigationDestination> _buildDestinations(
    BuildContext context,
    bool showUpdateBadge,
  ) {
    final s = S.of(context);
    return [
      NavigationDestination(
        icon: const Icon(Icons.library_music_outlined),
        selectedIcon: const Icon(Icons.library_music),
        label: s.navMy,
      ),
      NavigationDestination(
        icon: const Icon(Icons.menu_book_outlined),
        selectedIcon: const Icon(Icons.menu_book),
        label: s.navComics,
      ),
      NavigationDestination(
        icon: Badge(
          isLabelVisible: showUpdateBadge,
          child: const Icon(Icons.settings_outlined),
        ),
        selectedIcon: Badge(
          isLabelVisible: showUpdateBadge,
          child: const Icon(Icons.settings),
        ),
        label: s.navSettings,
      ),
    ];
  }

  void _handleDestinationSelected(int index) {
    if (_currentIndex == index) {
      return;
    }

    setState(() {
      _currentIndex = index;
    });

    _selection.value = index;
    _tabs.animateTo(index);

    if (index == _settingsTabIndex) {
      ref.read(settingsCacheRefreshTriggerProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kTabScrollDuration;
    if (_tabs.animationDuration != duration) {
      _tabs.dispose();
      _tabs = TabController(
        length: 3,
        vsync: this,
        initialIndex: _currentIndex,
        animationDuration: duration,
      );
    }
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final showUpdateBadge = ref.watch(showUpdateRedDotProvider);
    final destinations = _buildDestinations(context, showUpdateBadge);

    if (isLandscape) {
      // 横屏布局：使用 NavigationRail
      final landscapeScaffold = Scaffold(
        body: Stack(
          children: [
            // 主内容区域
            Row(
              children: [
                // 侧边导航栏
                SafeArea(
                  child: SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight:
                            MediaQuery.of(context).size.height -
                            MediaQuery.of(context).padding.top -
                            MediaQuery.of(context).padding.bottom,
                      ),
                      child: IntrinsicHeight(
                        child: _buildNavigationRail(destinations),
                      ),
                    ),
                  ),
                ),
                const VerticalDivider(thickness: 1, width: 1),
                // 页面内容
                Expanded(
                  child: Consumer(
                    builder: (context, ref, child) {
                      final authState = ref.watch(authProvider);
                      final isOfflineMode =
                          _currentIndex == 0 &&
                          authState.currentUser != null &&
                          !authState.isLoggedIn &&
                          authState.error != null;

                      final pages = PageStorage(
                        bucket: _bucket,
                        child: _buildPages(),
                      );
                      final miniPlayer = Consumer(
                        builder: (context, ref, child) {
                          final currentTrack = ref.watch(currentTrackProvider);
                          return currentTrack.when(
                            data: (track) => track != null
                                ? const MiniPlayer()
                                : const SizedBox.shrink(),
                            loading: () => const SizedBox.shrink(),
                            error: (_, __) => const SizedBox.shrink(),
                          );
                        },
                      );

                      final content = Column(
                        children: [
                          Expanded(child: pages),
                          miniPlayer,
                        ],
                      );

                      return Padding(
                        padding: EdgeInsets.only(top: isOfflineMode ? 30 : 0),
                        child: SafeArea(
                          top: false,
                          bottom: true,
                          child: content,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            // 离线模式提示横幅（覆盖在顶部）
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Consumer(
                builder: (context, ref, child) {
                  final authState = ref.watch(authProvider);
                  final isOfflineMode =
                      _currentIndex == 0 &&
                      authState.currentUser != null &&
                      !authState.isLoggedIn &&
                      authState.error != null;

                  if (!isOfflineMode) {
                    return const SizedBox.shrink();
                  }

                  final topPadding = MediaQuery.of(context).padding.top;

                  return Container(
                    width: double.infinity,
                    padding: EdgeInsets.fromLTRB(12, topPadding + 4, 12, 4),
                    color: Colors.orange.shade800,
                    child: Row(
                      children: [
                        const Icon(
                          Icons.cloud_off,
                          size: 14,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            S.of(context).offlineModeMessage,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () async {
                            final notifier = ref.read(authProvider.notifier);
                            await notifier.retryConnection();
                          },
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            S.of(context).retry,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
      return landscapeScaffold;
    }

    // 竖屏布局：播放条和应用标签栏共同组成底部 Dock。
    final miniPlayer = ref
        .watch(currentTrackProvider)
        .when<Widget?>(
          data: (track) => track != null ? const MiniPlayer() : null,
          loading: () => null,
          error: (_, __) => null,
        );
    final bottomDock = AppBottomDock(
      selectedIndex: _currentIndex,
      onDestinationSelected: _handleDestinationSelected,
      destinations: destinations,
      miniPlayer: miniPlayer,
    );

    final portraitScaffold = Scaffold(
      body: Stack(
        children: [
          // 主内容
          Consumer(
            builder: (context, ref, child) {
              final authState = ref.watch(authProvider);
              final isOfflineMode =
                  _currentIndex == 0 &&
                  authState.currentUser != null &&
                  !authState.isLoggedIn &&
                  authState.error != null;

              return Padding(
                padding: EdgeInsets.only(top: isOfflineMode ? 30 : 0),
                child: SafeArea(
                  top: false,
                  bottom: false,
                  child: PageStorage(bucket: _bucket, child: _buildPages()),
                ),
              );
            },
          ),
          // 离线模式提示横幅（覆盖在顶部）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Consumer(
              builder: (context, ref, child) {
                final authState = ref.watch(authProvider);
                final isOfflineMode =
                    _currentIndex == 0 &&
                    authState.currentUser != null &&
                    !authState.isLoggedIn &&
                    authState.error != null;

                if (!isOfflineMode) {
                  return const SizedBox.shrink();
                }

                final topPadding = MediaQuery.of(context).padding.top;

                return Container(
                  width: double.infinity,
                  padding: EdgeInsets.fromLTRB(12, topPadding + 4, 12, 4),
                  color: Colors.orange.shade800,
                  child: Row(
                    children: [
                      const Icon(
                        Icons.cloud_off,
                        size: 14,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          S.of(context).offlineModeMessage,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          final notifier = ref.read(authProvider.notifier);
                          await notifier.retryConnection();
                        },
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          S.of(context).retry,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: bottomDock,
    );
    return AppBottomDockTransitionScope(child: portraitScaffold);
  }

  Widget _buildNavigationRail(List<NavigationDestination> destinations) {
    return NavigationRail(
      selectedIndex: _currentIndex,
      onDestinationSelected: _handleDestinationSelected,
      labelType: NavigationRailLabelType.selected,
      destinations: destinations
          .map(
            (dest) => NavigationRailDestination(
              icon: dest.icon,
              selectedIcon: dest.selectedIcon,
              label: Text(dest.label),
            ),
          )
          .toList(),
    );
  }
}

class _MainTabPage extends StatefulWidget {
  const _MainTabPage({
    super.key,
    required this.index,
    required this.selection,
    required this.child,
  });
  final int index;
  final ValueNotifier<int> selection;
  final Widget child;
  @override
  State<_MainTabPage> createState() => _MainTabPageState();
}

class _MainTabPageState extends State<_MainTabPage>
    with AutomaticKeepAliveClientMixin {
  bool _visited = false;
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ValueListenableBuilder<int>(
      valueListenable: widget.selection,
      child: widget.child,
      builder: (context, index, child) {
        final selected = index == widget.index;
        _visited |= selected;
        return _visited
            ? HeroMode(enabled: selected, child: child!)
            : const SizedBox.shrink();
      },
    );
  }
}
