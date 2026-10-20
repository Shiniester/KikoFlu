import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/audio_source.dart';
import '../services/storage_service.dart';

class AudioSourceNotifier extends StateNotifier<AudioSource> {
  static const preferenceKey = 'audio_selected_source';

  AudioSourceNotifier()
    : super(AudioSource.fromValue(StorageService.getString(preferenceKey)));

  Future<void> select(AudioSource source) async {
    if (state == source) return;
    state = source;
    await StorageService.setString(preferenceKey, source.name);
  }
}

final audioSourceProvider =
    StateNotifierProvider<AudioSourceNotifier, AudioSource>(
      (ref) => AudioSourceNotifier(),
    );
