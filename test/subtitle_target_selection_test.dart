import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_database.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _track = AudioTrack(
  id: 'audio',
  title: 'scene01.wav',
  url: 'file:///scene01.wav',
  workId: 42,
  hash: 'audio',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (target, suffix) in [
    ('zh_hans', 'zh-Hans'),
    ('zh_hant', 'zh-Hant'),
    ('en', 'en'),
    ('ja', 'ja'),
  ]) {
    test('first automatic load prefers the saved $target target', () async {
      SharedPreferences.setMockInitialValues({
        TranslationLanguagePreferencesNotifier.keyTargetLanguage: target,
      });
      final directory = await Directory.systemTemp.createTemp(
        'subtitle-first-target-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final fallback = await File(
        '${directory.path}/scene01.srt',
      ).writeAsString('[00:01.00]fallback');
      final preferred = await File(
        '${directory.path}/scene01.$suffix.srt',
      ).writeAsString('[00:01.00]target');
      final container = ProviderContainer(
        overrides: [
          currentTrackProvider.overrideWith((ref) => Stream.value(_track)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(currentTrackProvider.future);
      await container
          .read(subtitleLibraryPriorityProvider.notifier)
          .updatePriority(SubtitleLibraryPriority.lowest);
      await container.read(lyricControllerProvider.notifier).loadLyricForTrack(
        _track,
        [
          {'type': 'text', 'title': 'scene01.srt', 'localPath': fallback.path},
          {
            'type': 'text',
            'title': 'scene01.$suffix.srt',
            'localPath': preferred.path,
          },
        ],
      );
      expect(
        container.read(lyricControllerProvider).lyrics.single.text,
        'target',
      );
    });
  }

  test(
    'library loading considers the target before exact-score fallback and respects origin priority',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp(
        'subtitle-library-target-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => directory.path);
      SharedPreferences.setMockInitialValues({
        TranslationLanguagePreferencesNotifier.keyTargetLanguage: 'en',
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      try {
        await SubtitleLibraryService.ensureInitialized();
        final root = await SubtitleLibraryService.getSubtitleLibraryDirectory();
        final library = await Directory(
          '${root.path}/RJ000042',
        ).create(recursive: true);
        final original = await File(
          '${library.path}/scene01.srt',
        ).writeAsString('[00:01.00]library original');
        final english = await File(
          '${library.path}/scene01.en.srt',
        ).writeAsString('[00:01.00]library English');
        await SubtitleDatabase.instance.insertFiles([
          SubtitleFileRecord(
            fileName: 'scene01.srt',
            relativePath: 'RJ000042/scene01.srt',
            category: 'RJ000042',
            workId: 42,
          ),
          SubtitleFileRecord(
            fileName: 'scene01.en.srt',
            relativePath: 'RJ000042/scene01.en.srt',
            category: 'RJ000042',
            workId: 42,
          ),
        ]);
        final workSubtitle = await File(
          '${directory.path}/scene01.ja.srt',
        ).writeAsString('[00:01.00]work Japanese');
        final container = ProviderContainer(
          overrides: [
            currentTrackProvider.overrideWith((ref) => Stream.value(_track)),
          ],
        );
        try {
          await container.read(currentTrackProvider.future);
          final controller = container.read(lyricControllerProvider.notifier);
          final files = [
            {
              'type': 'text',
              'title': 'scene01.ja.srt',
              'localPath': workSubtitle.path,
            },
          ];
          await container
              .read(subtitleLibraryPriorityProvider.notifier)
              .updatePriority(SubtitleLibraryPriority.highest);
          await controller.loadLyricForTrack(_track, files);
          expect(
            p.normalize(
              container.read(lyricControllerProvider).source!.localPath!,
            ),
            p.normalize(english.path),
          );
          expect(
            container.read(lyricControllerProvider).lyrics.single.text,
            'library English',
          );
          await container
              .read(subtitleLibraryPriorityProvider.notifier)
              .updatePriority(SubtitleLibraryPriority.lowest);
          await controller.loadLyricForTrack(_track, files);
          expect(
            container.read(lyricControllerProvider).lyrics.single.text,
            'work Japanese',
          );
          await english.delete();
          await controller.loadLyricForTrack(_track, const []);
          expect(
            p.normalize(
              container.read(lyricControllerProvider).source!.localPath!,
            ),
            p.normalize(original.path),
          );
        } finally {
          container.dispose();
        }
      } finally {
        await (await SubtitleDatabase.instance.database).close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
