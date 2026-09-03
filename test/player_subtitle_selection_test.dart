import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';

void main() {
  test(
    'manual subtitle selection switches only after a successful load',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kikoflu-subtitle',
      );
      addTearDown(() => directory.delete(recursive: true));
      final subtitle = File(
        '${directory.path}${Platform.pathSeparator}new.srt',
      );
      await subtitle.writeAsString(
        '1\n00:00:00,000 --> 00:00:02,000\nnew subtitle\n',
      );
      const track = AudioTrack(
        id: 'manual-subtitle-track',
        title: 'audio.wav',
        url: 'audio.wav',
        workId: 9,
      );
      final previous = LyricState(
        lyrics: [
          LyricLine(
            startTime: Duration.zero,
            endTime: const Duration(seconds: 1),
            text: 'old subtitle',
          ),
        ],
        source: const LyricSourceDescriptor(
          title: 'old.srt',
          type: LyricSourceType.localFile,
          localPath: 'old.srt',
          workId: 9,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          currentTrackProvider.overrideWith((ref) => Stream.value(track)),
          lyricControllerProvider.overrideWith(
            (ref) => LyricController(ref, initialState: previous),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(currentTrackProvider.future);
      final controller = container.read(lyricControllerProvider.notifier);

      await controller.selectLyricManually({
        'title': 'new.srt',
        'localPath': subtitle.path,
        'workId': 9,
      }, workId: 9);
      expect(
        container.read(lyricControllerProvider).lyrics.single.text,
        'new subtitle',
      );
      expect(
        container.read(lyricControllerProvider).source?.localPath,
        subtitle.path,
      );

      await expectLater(
        controller.selectLyricManually({
          'title': 'missing.srt',
          'localPath': '${directory.path}${Platform.pathSeparator}missing.srt',
          'workId': 9,
        }, workId: 9),
        throwsA(isA<Object>()),
      );
      expect(
        container.read(lyricControllerProvider).lyrics.single.text,
        'new subtitle',
      );
      expect(
        container.read(lyricControllerProvider).source?.localPath,
        subtitle.path,
      );
    },
  );
}
