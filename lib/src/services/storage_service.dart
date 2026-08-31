import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'log_service.dart';

class StorageService {
  static late Box _settingsBox;
  static late Box _userBox;
  static late Box _cacheBox;
  static late SharedPreferences _prefs;
  static Future<void>? _criticalInitFuture;
  static Future<void>? _secondaryInitFuture;
  static bool _criticalInitialized = false;
  static bool _secondaryInitialized = false;

  static Future<void> init({SharedPreferences? preferences}) async {
    await initCritical(preferences: preferences);
    await initSecondary();
  }

  /// Opens only the stores required to restore the current account and build
  /// the first interactive frame.
  static Future<void> initCritical({SharedPreferences? preferences}) {
    if (_criticalInitialized) {
      if (preferences != null) _prefs = preferences;
      return Future.value();
    }
    return _criticalInitFuture ??= _initializeCritical(preferences);
  }

  static Future<void> _initializeCritical(
    SharedPreferences? preferences,
  ) async {
    try {
      final results = await Future.wait<dynamic>([
        Hive.openBox('users'),
        preferences == null
            ? SharedPreferences.getInstance()
            : Future<SharedPreferences>.value(preferences),
      ]);
      _userBox = results[0] as Box;
      _prefs = results[1] as SharedPreferences;
      _criticalInitialized = true;
    } finally {
      _criticalInitFuture = null;
    }
  }

  /// Opens legacy settings/cache boxes after the first frame. Their format and
  /// APIs remain unchanged for compatibility with existing data and callers.
  static Future<void> initSecondary() {
    if (_secondaryInitialized) return Future.value();
    return _secondaryInitFuture ??= _initializeSecondary();
  }

  static Future<void> _initializeSecondary() async {
    try {
      final results = await Future.wait<Box>([
        Hive.openBox('settings'),
        Hive.openBox('cache'),
      ]);
      _settingsBox = results[0];
      _cacheBox = results[1];
      _secondaryInitialized = true;
    } finally {
      _secondaryInitFuture = null;
    }
  }

  // Settings
  static Future<void> setSetting(String key, dynamic value) async {
    await _settingsBox.put(key, value);
  }

  static T? getSetting<T>(String key, {T? defaultValue}) {
    return _settingsBox.get(key, defaultValue: defaultValue) as T?;
  }

  static Future<void> removeSetting(String key) async {
    await _settingsBox.delete(key);
  }

  // User data
  static Future<void> setUser(String key, dynamic value) async {
    await _userBox.put(key, value);
  }

  static T? getUser<T>(String key, {T? defaultValue}) {
    return _userBox.get(key, defaultValue: defaultValue) as T?;
  }

  static Future<void> removeUser(String key) async {
    await _userBox.delete(key);
  }

  static List<String> getAllUserKeys() {
    return _userBox.keys.cast<String>().toList();
  }

  // Cache
  static Future<void> setCache(String key, dynamic value) async {
    await _cacheBox.put(key, value);
  }

  static T? getCache<T>(String key, {T? defaultValue}) {
    return _cacheBox.get(key, defaultValue: defaultValue) as T?;
  }

  static Future<void> removeCache(String key) async {
    await _cacheBox.delete(key);
  }

  static Future<void> clearCache() async {
    await _cacheBox.clear();
  }

  // SharedPreferences methods
  static Future<void> setString(String key, String value) async {
    await _prefs.setString(key, value);
  }

  static String? getString(String key) {
    return _prefs.getString(key);
  }

  static Future<void> setBool(String key, bool value) async {
    await _prefs.setBool(key, value);
  }

  static bool? getBool(String key) {
    return _prefs.getBool(key);
  }

  static Future<void> setInt(String key, int value) async {
    await _prefs.setInt(key, value);
  }

  static int? getInt(String key) {
    return _prefs.getInt(key);
  }

  static Future<void> remove(String key) async {
    await _prefs.remove(key);
  }

  static Future<void> clear() async {
    await _prefs.clear();
  }

  // Get SharedPreferences instance
  static Future<SharedPreferences> getPrefs() async {
    return _prefs;
  }

  // JSON Map methods for complex objects
  static Future<void> setMap(String key, Map<String, dynamic> value) async {
    await _prefs.setString(key, jsonEncode(value));
  }

  static Map<String, dynamic>? getMap(String key) {
    final jsonString = _prefs.getString(key);
    if (jsonString != null) {
      try {
        return jsonDecode(jsonString) as Map<String, dynamic>;
      } catch (e) {
        logOutput('Error decoding JSON for key $key: $e');
        return null;
      }
    }
    return null;
  }

  /// Returns HTTP headers with server cookie if configured.
  /// Only includes the Cookie header when a non-empty value exists.
  static Map<String, String> get serverCookieHeaders {
    final cookie = getString('server_cookie');
    if (cookie != null && cookie.isNotEmpty) {
      return {'Cookie': cookie};
    }
    return {};
  }
}
