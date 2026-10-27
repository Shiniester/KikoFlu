import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_slice.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/audio_slice_presentation_provider.dart';

void main() {
  test(
    'active slice changes at shared boundaries independently of selection',
    () async {
      const first = AudioSlice(startMs: 10000, endMs: 20000);
      const second = AudioSlice(startMs: 20000, endMs: 30000);
      final container = ProviderContainer(
        overrides: [
          audioSliceStateProvider.overrideWith(
            (ref) => Stream.value(
              const AudioSliceState().copyWith(
                trackKey: 'track',
                slices: const [first, second],
              ),
            ),
          ),
          positionProvider.overrideWith(
            (ref) => Stream.value(const Duration(milliseconds: 20000)),
          ),
        ],
      );
      addTearDown(container.dispose);

      await Future.wait([
        container.read(audioSliceStateProvider.future),
        container.read(positionProvider.future),
      ]);
      container.read(audioSliceSelectionProvider.notifier).state =
          const AudioSliceSelection(trackKey: 'track', slice: first);

      expect(container.read(activeAudioSliceProvider), second);
      expect(container.read(selectedAudioSliceProvider), first);
    },
  );
}
