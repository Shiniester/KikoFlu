import 'dart:io';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('changing the target keeps a manually selected subtitle', () async {
    SharedPreferences.setMockInitialValues({
      TranslationLanguagePreferencesNotifier.keyTargetLanguage: 'en',
    });
    final directory = await Directory.systemTemp.createTemp(
      'subtitle-manual-target-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final english = await File(
      '${directory.path}/scene01.en.srt',
    ).writeAsString('[00:01.00]English');
    final japanese = await File(
      '${directory.path}/scene01.ja.srt',
    ).writeAsString('[00:01.00]Japanese');
    const track = AudioTrack(
      id: 'audio',
      title: 'scene01.wav',
      url: 'file:///scene01.wav',
      workId: 42,
      hash: 'audio',
    );
    final container = ProviderContainer(
      overrides: [
        currentTrackProvider.overrideWith((ref) => Stream.value(track)),
        playbackLyricFileTreeLoaderProvider.overrideWithValue((_) async => []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(currentTrackProvider.future);
    await container
        .read(subtitleLibraryPriorityProvider.notifier)
        .updatePriority(SubtitleLibraryPriority.lowest);
    container.read(fileListControllerProvider.notifier).updateFiles([
      {'type': 'text', 'title': 'scene01.en.srt', 'localPath': english.path},
      {'type': 'text', 'title': 'scene01.ja.srt', 'localPath': japanese.path},
    ], workId: 42);
    final automatic = Completer<void>();
    final subscription = container.listen(lyricControllerProvider, (_, state) {
      if (state.source?.localPath == english.path && !automatic.isCompleted) {
        automatic.complete();
      }
    });
    addTearDown(subscription.close);
    container.read(lyricAutoLoaderProvider);
    await automatic.future;
    await container.read(lyricControllerProvider.notifier).selectLyricManually({
      'title': 'scene01.ja.srt',
      'localPath': japanese.path,
    }, workId: 42);
    await container
        .read(translationLanguagePreferencesProvider.notifier)
        .updateTargetLanguage(TranslationTargetLanguage.zhHant);
    await container.read(effectiveTranslationTargetLocaleProvider.future);
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(lyricControllerProvider).source?.localPath,
      japanese.path,
    );
    expect(
      container.read(lyricControllerProvider).lyrics.single.text,
      'Japanese',
    );
  });

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
