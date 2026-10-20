import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "我的"界面标签页显示设置
class MyTabsDisplaySettings {
  static const defaultPageOrder = [
    'popular',
    'recommended',
    'onlineMarks',
    'history',
    'playlists',
    'downloads',
    'subtitleLibrary',
  ];

  final bool showOnlineMarks;
  final bool showPlaylists;
  final bool showSubtitleLibrary;
  final List<String> pageOrder;

  const MyTabsDisplaySettings({
    this.showOnlineMarks = true,
    this.showPlaylists = true,
    this.showSubtitleLibrary = true,
    this.pageOrder = defaultPageOrder,
  });

  MyTabsDisplaySettings copyWith({
    bool? showOnlineMarks,
    bool? showPlaylists,
    bool? showSubtitleLibrary,
    List<String>? pageOrder,
  }) {
    return MyTabsDisplaySettings(
      showOnlineMarks: showOnlineMarks ?? this.showOnlineMarks,
      showPlaylists: showPlaylists ?? this.showPlaylists,
      showSubtitleLibrary: showSubtitleLibrary ?? this.showSubtitleLibrary,
      pageOrder: pageOrder ?? this.pageOrder,
    );
  }
}

/// "我的"界面标签页显示设置控制器
class MyTabsDisplaySettingsNotifier
    extends StateNotifier<MyTabsDisplaySettings> {
  static const String _onlineMarksKey = 'my_tabs_show_online_marks';
  static const String _playlistsKey = 'my_tabs_show_playlists';
  static const String _subtitleLibraryKey = 'my_tabs_show_subtitle_library';
  static const String _pageOrderKey = 'my_tabs_page_order';
  bool _changedLocally = false;

  MyTabsDisplaySettingsNotifier() : super(const MyTabsDisplaySettings()) {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || _changedLocally) return;
      state = MyTabsDisplaySettings(
        showOnlineMarks: prefs.getBool(_onlineMarksKey) ?? true,
        showPlaylists: prefs.getBool(_playlistsKey) ?? true,
        showSubtitleLibrary: prefs.getBool(_subtitleLibraryKey) ?? true,
        pageOrder:
            prefs.getStringList(_pageOrderKey) ??
            MyTabsDisplaySettings.defaultPageOrder,
      );
    } catch (e) {
      // 加载失败，使用默认值
      state = const MyTabsDisplaySettings();
    }
  }

  Future<void> setShowOnlineMarks(bool value) async {
    _changedLocally = true;
    state = state.copyWith(showOnlineMarks: value);
    await _saveSetting(_onlineMarksKey, value);
  }

  Future<void> setShowPlaylists(bool value) async {
    _changedLocally = true;
    state = state.copyWith(showPlaylists: value);
    await _saveSetting(_playlistsKey, value);
  }

  Future<void> setShowSubtitleLibrary(bool value) async {
    _changedLocally = true;
    state = state.copyWith(showSubtitleLibrary: value);
    await _saveSetting(_subtitleLibraryKey, value);
  }

  Future<void> setPageOrder(List<String> value) async {
    _changedLocally = true;
    state = state.copyWith(pageOrder: value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_pageOrderKey, value);
    } catch (e) {
      // 保存失败时静默处理
    }
  }

  Future<void> resetToDefault() async {
    _changedLocally = true;
    state = const MyTabsDisplaySettings();
    await _saveSetting(_onlineMarksKey, state.showOnlineMarks);
    await _saveSetting(_playlistsKey, state.showPlaylists);
    await _saveSetting(_subtitleLibraryKey, state.showSubtitleLibrary);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_pageOrderKey, state.pageOrder);
    } catch (e) {
      // 保存失败时静默处理
    }
  }

  Future<void> _saveSetting(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (e) {
      // 保存失败时静默处理
    }
  }
}

/// "我的"界面标签页显示设置提供者
final myTabsDisplayProvider =
    StateNotifierProvider<MyTabsDisplaySettingsNotifier, MyTabsDisplaySettings>(
      (ref) {
        return MyTabsDisplaySettingsNotifier();
      },
    );
