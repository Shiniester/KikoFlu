import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放器按钮类型
enum PlayerButtonType {
  seekBackward('后退10秒', 'seek_backward'),
  seekForward('前进10秒', 'seek_forward'),
  sleepTimer('定时器', 'sleep_timer'),
  mark('标记作品', 'mark'),
  volume('音量控制', 'volume'),
  speed('播放速度', 'speed'),
  repeat('循环模式', 'repeat'),
  queue('播放列表', 'queue'),
  detail('查看详情', 'detail'),
  subtitleAdjustment('字幕轴调整', 'subtitle_adjustment'),
  floatingLyric('悬浮字幕', 'floating_lyric');

  final String label;
  final String key;
  const PlayerButtonType(this.label, this.key);
}

/// 播放器按钮配置状态
class PlayerButtonsConfig {
  final List<PlayerButtonType> buttonOrder;

  const PlayerButtonsConfig({required this.buttonOrder});

  /// 默认配置 - 移动端
  static const defaultMobile = PlayerButtonsConfig(
    buttonOrder: [
      PlayerButtonType.repeat,
      PlayerButtonType.seekBackward,
      PlayerButtonType.mark,
      PlayerButtonType.seekForward,
      PlayerButtonType.queue,
      PlayerButtonType.floatingLyric,
      PlayerButtonType.sleepTimer,
      PlayerButtonType.speed,
      PlayerButtonType.subtitleAdjustment,
      PlayerButtonType.detail,
    ],
  );

  /// 默认配置 - 桌面端
  static const defaultDesktop = PlayerButtonsConfig(
    buttonOrder: [
      PlayerButtonType.repeat,
      PlayerButtonType.seekBackward,
      PlayerButtonType.mark,
      PlayerButtonType.seekForward,
      PlayerButtonType.queue,
      PlayerButtonType.floatingLyric,
      PlayerButtonType.sleepTimer,
      PlayerButtonType.volume,
      PlayerButtonType.speed,
      PlayerButtonType.subtitleAdjustment,
      PlayerButtonType.detail,
    ],
  );

  static const legacyDefaultMobile = <PlayerButtonType>[
    PlayerButtonType.seekBackward,
    PlayerButtonType.seekForward,
    PlayerButtonType.floatingLyric,
    PlayerButtonType.sleepTimer,
    PlayerButtonType.mark,
    PlayerButtonType.speed,
    PlayerButtonType.repeat,
    PlayerButtonType.subtitleAdjustment,
    PlayerButtonType.detail,
  ];

  static const legacyDefaultDesktop = <PlayerButtonType>[
    PlayerButtonType.seekBackward,
    PlayerButtonType.seekForward,
    PlayerButtonType.floatingLyric,
    PlayerButtonType.sleepTimer,
    PlayerButtonType.volume,
    PlayerButtonType.mark,
    PlayerButtonType.speed,
    PlayerButtonType.repeat,
    PlayerButtonType.subtitleAdjustment,
    PlayerButtonType.detail,
  ];

  /// Default used by the first Salt-style player revision. Only exact matches
  /// are migrated, so a user-defined order is never overwritten.
  static const previousDefaultMobile = <PlayerButtonType>[
    PlayerButtonType.repeat,
    PlayerButtonType.seekBackward,
    PlayerButtonType.seekForward,
    PlayerButtonType.floatingLyric,
    PlayerButtonType.sleepTimer,
    PlayerButtonType.mark,
    PlayerButtonType.speed,
    PlayerButtonType.subtitleAdjustment,
    PlayerButtonType.detail,
  ];

  static const previousDefaultDesktop = <PlayerButtonType>[
    PlayerButtonType.repeat,
    PlayerButtonType.seekBackward,
    PlayerButtonType.seekForward,
    PlayerButtonType.floatingLyric,
    PlayerButtonType.sleepTimer,
    PlayerButtonType.volume,
    PlayerButtonType.mark,
    PlayerButtonType.speed,
    PlayerButtonType.subtitleAdjustment,
    PlayerButtonType.detail,
  ];

  /// 获取当前布局可直接显示的按钮。
  List<PlayerButtonType> getVisibleButtons({required int slotCount}) {
    assert(slotCount >= 0);
    return buttonOrder.take(slotCount).toList(growable: false);
  }

  /// 获取更多菜单中的按钮
  List<PlayerButtonType> getMoreButtons({required int slotCount}) {
    assert(slotCount >= 0);
    return buttonOrder.skip(slotCount).toList(growable: false);
  }

  /// 从JSON加载
  factory PlayerButtonsConfig.fromJson(Map<String, dynamic> json) {
    final orderKeys = (json['buttonOrder'] as List<dynamic>).cast<String>();
    final buttonOrder = orderKeys
        .map(
          (key) => PlayerButtonType.values.firstWhere(
            (type) => type.key == key,
            orElse: () => PlayerButtonType.seekBackward,
          ),
        )
        .toList();
    return PlayerButtonsConfig(buttonOrder: buttonOrder);
  }

  /// 转换为JSON
  Map<String, dynamic> toJson() {
    return {'buttonOrder': buttonOrder.map((type) => type.key).toList()};
  }

  PlayerButtonsConfig copyWith({List<PlayerButtonType>? buttonOrder}) {
    return PlayerButtonsConfig(buttonOrder: buttonOrder ?? this.buttonOrder);
  }
}

/// 播放器按钮配置控制器
class PlayerButtonsConfigController extends StateNotifier<PlayerButtonsConfig> {
  static const String _prefKey = 'player_buttons_config';
  static const String _prefKeyDesktop = 'player_buttons_config_desktop';

  final bool _isDesktop;
  bool _changedLocally = false;

  PlayerButtonsConfigController(this._isDesktop)
    : super(
        _isDesktop
            ? PlayerButtonsConfig.defaultDesktop
            : PlayerButtonsConfig.defaultMobile,
      ) {
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_changedLocally) return;
      final key = _isDesktop ? _prefKeyDesktop : _prefKey;
      final jsonString = prefs.getString(key);

      if (jsonString != null) {
        var savedOrder = (jsonString.split(','))
            .map(
              (key) => PlayerButtonType.values.firstWhere(
                (type) => type.key == key,
                orElse: () => PlayerButtonType.seekBackward,
              ),
            )
            .toList();

        // 获取默认配置，用于合并新按钮
        final defaultOrder = _isDesktop
            ? PlayerButtonsConfig.defaultDesktop.buttonOrder
            : PlayerButtonsConfig.defaultMobile.buttonOrder;
        final legacyDefault = _isDesktop
            ? PlayerButtonsConfig.legacyDefaultDesktop
            : PlayerButtonsConfig.legacyDefaultMobile;
        final previousDefault = _isDesktop
            ? PlayerButtonsConfig.previousDefaultDesktop
            : PlayerButtonsConfig.previousDefaultMobile;
        final migratedDefault =
            _sameOrder(savedOrder, legacyDefault) ||
            _sameOrder(savedOrder, previousDefault);
        if (migratedDefault) {
          savedOrder = List<PlayerButtonType>.from(defaultOrder);
        }

        // 找出新添加的按钮（在默认配置中存在但保存的配置中不存在）
        final newButtons = defaultOrder
            .where((button) => !savedOrder.contains(button))
            .toList();

        // 将新按钮添加到末尾
        final mergedOrder = [...savedOrder, ...newButtons];

        state = PlayerButtonsConfig(buttonOrder: mergedOrder);

        // 如果有新按钮被添加，保存更新后的配置
        if (migratedDefault || newButtons.isNotEmpty) {
          await _saveConfig();
        }
      }
    } catch (e) {
      // 如果加载失败，使用默认配置
      state = _isDesktop
          ? PlayerButtonsConfig.defaultDesktop
          : PlayerButtonsConfig.defaultMobile;
    }
  }

  bool _sameOrder(List<PlayerButtonType> first, List<PlayerButtonType> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  Future<void> updateButtonOrder(List<PlayerButtonType> newOrder) async {
    _changedLocally = true;
    state = state.copyWith(buttonOrder: newOrder);
    await _saveConfig();
  }

  Future<void> _saveConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _isDesktop ? _prefKeyDesktop : _prefKey;
      final orderString = state.buttonOrder.map((type) => type.key).join(',');
      await prefs.setString(key, orderString);
    } catch (e) {
      // 保存失败时静默处理
    }
  }

  Future<void> resetToDefault() async {
    _changedLocally = true;
    state = _isDesktop
        ? PlayerButtonsConfig.defaultDesktop
        : PlayerButtonsConfig.defaultMobile;
    await _saveConfig();
  }
}

/// 移动端按钮配置Provider
final playerButtonsConfigMobileProvider =
    StateNotifierProvider<PlayerButtonsConfigController, PlayerButtonsConfig>(
      (ref) => PlayerButtonsConfigController(false),
    );

/// 桌面端按钮配置Provider
final playerButtonsConfigDesktopProvider =
    StateNotifierProvider<PlayerButtonsConfigController, PlayerButtonsConfig>(
      (ref) => PlayerButtonsConfigController(true),
    );
