import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/audio_slice.dart';
import '../models/audio_track.dart';

String audioSliceTrackKey(AudioTrack track) {
  final identity = track.hash?.isNotEmpty == true ? track.hash! : track.id;
  return track.workId == null ? identity : '${track.workId}:$identity';
}

abstract interface class AudioSliceStore {
  Future<List<AudioSlice>> load(String trackKey);

  Future<bool> write(String trackKey, List<AudioSlice> slices);

  Future<bool> clear(String trackKey);
}

class SharedPreferencesAudioSliceStore implements AudioSliceStore {
  const SharedPreferencesAudioSliceStore();

  static const String storagePrefix = 'audio_slices_v1:';

  static String storageKey(String trackKey) =>
      '$storagePrefix${Uri.encodeComponent(trackKey)}';

  @override
  Future<List<AudioSlice>> load(String trackKey) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(storageKey(trackKey));
    if (encoded == null || encoded.isEmpty) return const [];

    final json = jsonDecode(encoded);
    if (json is! List) throw const FormatException('Invalid audio slices');
    final slices = json
        .map((item) {
          if (item is! Map ||
              item['startMs'] is! int ||
              item['endMs'] is! int) {
            throw const FormatException('Invalid audio slice');
          }
          return AudioSlice(
            startMs: item['startMs'] as int,
            endMs: item['endMs'] as int,
          );
        })
        .toList(growable: false);
    _validateSlices(slices);
    return slices;
  }

  @override
  Future<bool> write(String trackKey, List<AudioSlice> slices) async {
    _validateSlices(slices);
    final prefs = await SharedPreferences.getInstance();
    final key = storageKey(trackKey);
    final previous = prefs.getString(key);
    if (slices.isEmpty) {
      return _mutateWithRollback(prefs, key, previous, () => prefs.remove(key));
    }
    final encoded = jsonEncode(
      slices
          .map((slice) => {'startMs': slice.startMs, 'endMs': slice.endMs})
          .toList(),
    );
    return _mutateWithRollback(
      prefs,
      key,
      previous,
      () => prefs.setString(key, encoded),
    );
  }

  @override
  Future<bool> clear(String trackKey) async {
    final prefs = await SharedPreferences.getInstance();
    final key = storageKey(trackKey);
    final previous = prefs.getString(key);
    return _mutateWithRollback(prefs, key, previous, () => prefs.remove(key));
  }

  Future<bool> _mutateWithRollback(
    SharedPreferences prefs,
    String key,
    String? previous,
    Future<bool> Function() mutation,
  ) async {
    try {
      if (await mutation()) return true;
    } catch (_) {
      await _restore(prefs, key, previous);
      rethrow;
    }
    await _restore(prefs, key, previous);
    return false;
  }

  Future<void> _restore(
    SharedPreferences prefs,
    String key,
    String? previous,
  ) async {
    try {
      if (previous == null) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, previous);
      }
    } catch (_) {}
  }

  static void _validateSlices(List<AudioSlice> slices) {
    for (var index = 0; index < slices.length; index++) {
      final slice = slices[index];
      if (slice.startMs < 0 || slice.endMs <= slice.startMs) {
        throw const FormatException('Audio slice range must be positive');
      }
      if (index > 0 && slices[index - 1].endMs > slice.startMs) {
        throw const FormatException('Audio slices overlap or are unsorted');
      }
    }
  }
}
