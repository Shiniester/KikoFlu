import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class VideoLibrary extends ChangeNotifier {
  VideoLibrary({SharedPreferences? preferences})
    : _providedPreferences = preferences;

  static const _positionsKey = 'video_resume_positions_v1';
  static const _volumeKey = 'video_volume_v1';

  final SharedPreferences? _providedPreferences;
  SharedPreferences? _preferences;
  Future<void>? _initializing;
  Future<void> _writeTail = Future<void>.value();
  final Map<String, int> _positions = {};
  double _volume = 100;
  bool _disposed = false;

  Future<void> initialize() {
    if (_preferences != null) return Future.value();
    return _initializing ??= _load().whenComplete(() => _initializing = null);
  }

  Future<void> _load() async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    _preferences = preferences;
    final positions = preferences.getString(_positionsKey);
    if (positions != null) {
      try {
        final decoded = jsonDecode(positions);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final value = entry.value;
            if (entry.key is String && value is num && value >= 0) {
              _positions[entry.key as String] = value.toInt();
            }
          }
        }
      } on FormatException {
        // A malformed local preference is ignored and replaced on next save.
      }
    }
    final savedVolume = preferences.getDouble(_volumeKey);
    if (savedVolume != null && savedVolume.isFinite) {
      _volume = savedVolume.clamp(0, 100).toDouble();
    }
    _notify();
  }

  Duration positionFor(String videoId) =>
      Duration(milliseconds: _positions[videoId] ?? 0);

  Future<void> savePosition(String videoId, Duration position) async {
    await initialize();
    final milliseconds = position.inMilliseconds < 0
        ? 0
        : position.inMilliseconds;
    if (_positions[videoId] == milliseconds) return;
    _positions[videoId] = milliseconds;
    await _queueWrite(
      () => _preferences!.setString(_positionsKey, jsonEncode(_positions)),
    );
    _notify();
  }

  double get volume => _volume;

  Future<void> setVolume(double value) async {
    if (!value.isFinite) throw ArgumentError.value(value, 'value');
    await initialize();
    final volume = value.clamp(0, 100).toDouble();
    if (_volume == volume) return;
    _volume = volume;
    await _queueWrite(() => _preferences!.setDouble(_volumeKey, volume));
    _notify();
  }

  Future<void> _queueWrite(Future<bool> Function() write) {
    final pending = _writeTail.then((_) async {
      await write();
    });
    _writeTail = pending.catchError((_) {});
    return pending;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
