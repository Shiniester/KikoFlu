import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/audio_slice.dart';
import 'audio_provider.dart';

@immutable
class AudioSliceSelection {
  const AudioSliceSelection({required this.trackKey, required this.slice});

  final String trackKey;
  final AudioSlice slice;
}

final audioSliceSelectionProvider = StateProvider<AudioSliceSelection?>(
  (ref) => null,
);

final selectedAudioSliceProvider = Provider<AudioSlice?>((ref) {
  final selection = ref.watch(audioSliceSelectionProvider);
  final state = ref.watch(audioSliceStateProvider).valueOrNull;
  if (selection == null ||
      state == null ||
      state.trackKey != selection.trackKey ||
      !state.slices.contains(selection.slice)) {
    return null;
  }
  return selection.slice;
});

final activeAudioSliceProvider = Provider<AudioSlice?>((ref) {
  final state = ref.watch(audioSliceStateProvider).valueOrNull;
  final position = ref.watch(positionProvider).valueOrNull;
  if (state == null || state.trackKey == null || position == null) return null;

  final milliseconds = position.inMilliseconds;
  for (final slice in state.slices) {
    if (milliseconds >= slice.startMs && milliseconds < slice.endMs) {
      return slice;
    }
  }
  return null;
});
