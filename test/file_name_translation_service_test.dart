import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/file_name_translation_service.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/translation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> fileItem(String title) {
  return {'type': 'audio', 'title': title, 'hash': title};
}

Map<String, dynamic> folderItem(String title, List<dynamic> children) {
  return {'type': 'folder', 'title': title, 'children': children};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FileNameTranslationService', () {
    for (final target in ['zh_hans', 'zh_hant']) {
      test(
        'converts Chinese filenames locally in a mixed $target batch',
        () async {
          SharedPreferences.setMockInitialValues({
            TranslationLanguagePreferencesNotifier.keyTargetLanguage: target,
          });
          final requests = <(String, String?)>[];
          final chinese = target == 'zh_hans' ? '輕聲耳語.wav' : '轻声耳语.wav';
          final expected = target == 'zh_hans' ? '轻声耳语.wav' : '輕聲耳語.wav';
          final sourceLang = target == 'zh_hans' ? 'zh-tw' : 'zh-cn';
          final service = FileNameTranslationService(
            convertLocally: TranslationService().convertChineseLocally,
            translate: (text, {sourceLang}) async {
              requests.add((text, sourceLang));
              return text
                  .split('\n')
                  .map((name) => 'translated:$name')
                  .join('\n');
            },
            delay: (_) async {},
          );
          final result = await service.translateNames(
            names: ['こんにちは.wav', chinese, '少女の耳語.wav'],
            sourceLang: sourceLang,
          );
          expect(requests, [('こんにちは.wav\n少女の耳語.wav', 'ja')]);
          expect(result.translations, {
            'こんにちは.wav': 'translated:こんにちは.wav',
            chinese: expected,
            '少女の耳語.wav': 'translated:少女の耳語.wav',
          });
        },
      );
    }

    test('preserves Chinese names in a mixed translation batch', () async {
      final requests = <(String, String?)>[];
      final localSourceLanguages = <String?>[];
      final service = FileNameTranslationService(
        translate: (text, {sourceLang}) async {
          requests.add((text, sourceLang));
          return text.split('\n').map((line) => 'translated:$line').join('\n');
        },
        delay: (_) async {},
        convertLocally: (text, {sourceLang}) async {
          localSourceLanguages.add(sourceLang);
          return switch (text) {
            '轻声耳语.wav' || '简体标题.txt' => text,
            _ => null,
          };
        },
      );
      final result = await service.translateNames(
        names: ['轻声耳语.wav', 'こんにちは.wav', '简体标题.txt', '少女.wav'],
      );
      expect(requests, [('こんにちは.wav', 'ja'), ('少女.wav', null)]);
      expect(localSourceLanguages, [null, 'ja', null, null]);
      expect(result.names, ['轻声耳语.wav', 'こんにちは.wav', '简体标题.txt', '少女.wav']);
      expect(result.translations, {
        '轻声耳语.wav': '轻声耳语.wav',
        'こんにちは.wav': 'translated:こんにちは.wav',
        '简体标题.txt': '简体标题.txt',
        '少女.wav': 'translated:少女.wav',
      });
    });

    test('groups kana overrides apart from unknown source names', () async {
      final requests = <(String, String?)>[];
      final localSourceLanguages = <String?>[];
      final service = FileNameTranslationService(
        translate: (text, {sourceLang}) async {
          requests.add((text, sourceLang));
          return text
              .split('\n')
              .map((name) => '${sourceLang ?? 'auto'}:$name')
              .join('\n');
        },
        convertLocally: (text, {sourceLang}) async {
          localSourceLanguages.add(sourceLang);
          return null;
        },
        delay: (_) async {},
      );

      final result = await service.translateNames(
        names: ['firstかな.wav', 'plain.wav', 'secondカナ.wav'],
        sourceLang: 'unknown',
        maxChunkSize: 100,
      );

      expect(requests, [
        ('firstかな.wav\nsecondカナ.wav', 'ja'),
        ('plain.wav', null),
      ]);
      expect(localSourceLanguages, ['ja', null, 'ja']);
      expect(result.names, ['firstかな.wav', 'plain.wav', 'secondカナ.wav']);
      expect(result.translations, {
        'firstかな.wav': 'ja:firstかな.wav',
        'plain.wav': 'auto:plain.wav',
        'secondカナ.wav': 'ja:secondカナ.wav',
      });
    });

    test(
      'keeps chunk errors and progress indices global across source groups',
      () async {
        final requests = <(String, String?)>[];
        final progress = <String>[];
        final errors = <String>[];
        final delays = <Duration>[];
        final localSourceLanguages = <String?>[];
        final service = FileNameTranslationService(
          translate: (text, {sourceLang}) async {
            requests.add((text, sourceLang));
            if (text == 'bかな') throw StateError('failed');
            return '$sourceLang:$text';
          },
          convertLocally: (text, {sourceLang}) async {
            localSourceLanguages.add(sourceLang);
            return null;
          },
          delay: (duration) async => delays.add(duration),
        );

        final result = await service.translateNames(
          names: ['aかな', 'bかな', 'c'],
          sourceLang: 'CHI_HANS',
          maxChunkSize: 3,
          onProgress: (current, total) => progress.add('$current/$total'),
          onChunkError: (index, error) =>
              errors.add('$index:${error.runtimeType}'),
        );

        expect(requests, [('aかな', 'ja'), ('bかな', 'ja'), ('c', 'zh-cn')]);
        expect(localSourceLanguages, ['ja', 'ja', 'zh-cn']);
        expect(progress, ['1/3', '2/3', '3/3']);
        expect(errors, ['1:StateError']);
        expect(delays, [
          const Duration(milliseconds: 300),
          const Duration(milliseconds: 300),
        ]);
        expect(result.translations, {
          'aかな': 'ja:aかな',
          'bかな': 'bかな',
          'c': 'zh-cn:c',
        });
      },
    );

    test(
      'local filename conversion runs before a stale remote cache',
      () async {
        const text = '頭髮發展.wav';
        SharedPreferences.setMockInitialValues({
          TranslationLanguagePreferencesNotifier.keyTargetLanguage: 'zh_hans',
          'translation_cache_zh-tw_zh_Hans_${text.hashCode}': jsonEncode({
            'translation': 'stale remote translation',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }),
        });
        final translationService = TranslationService();
        final result = await FileNameTranslationService(
          translate: translationService.translate,
          convertLocally: translationService.convertChineseLocally,
          delay: (_) async {},
        ).translateNames(names: [text], sourceLang: 'CHI_HANT');

        expect(result.translations, {'頭髮發展.wav': '头发发展.wav'});
      },
    );

    test(
      'all simplified names require no request, progress or delay',
      () async {
        final service = FileNameTranslationService(
          translate: (text, {sourceLang}) async => fail('unexpected request'),
          delay: (_) async => fail('unexpected delay'),
          convertLocally: (text, {sourceLang}) async => text,
        );
        final result = await service.translateNames(
          names: ['简体标题', '轻声耳语.wav'],
          onProgress: (_, _) => fail('unexpected progress'),
        );
        expect(result.translations, {'简体标题': '简体标题', '轻声耳语.wav': '轻声耳语.wav'});
      },
    );

    test(
      'Chinese names remain translatable without a local converter',
      () async {
        final service = FileNameTranslationService(
          translate: (text, {sourceLang}) async => 'translated:$text',
        );
        final result = await service.translateNames(names: ['简体标题']);
        expect(result.translations, {'简体标题': 'translated:简体标题'});
      },
    );

    test(
      'splits names into newline chunks without exceeding limit when possible',
      () {
        final chunks = FileNameTranslationService.splitNamesIntoChunks([
          'aaaa',
          'bbbb',
          'cc',
        ], maxChunkSize: 9);

        expect(chunks, ['aaaa\nbbbb', 'cc']);
      },
    );

    test('translates collected file tree names and reports progress', () async {
      final translatedChunks = <String>[];
      final localSourceLanguages = <String?>[];
      final progress = <String>[];
      final service = FileNameTranslationService(
        translate: (text, {sourceLang}) async {
          expect(sourceLang, 'ja');
          translatedChunks.add(text);
          return text.split('\n').map((line) => 'translated:$line').join('\n');
        },
        convertLocally: (text, {sourceLang}) async {
          localSourceLanguages.add(sourceLang);
          return null;
        },
        delay: (_) async {},
      );

      final result = await service.translateFileTree(
        fileTree: [
          folderItem('Disc', [
            fileItem('track01.mp3'),
            fileItem('track02.mp3'),
          ]),
        ],
        sourceLang: 'ja',
        maxChunkSize: 100,
        onProgress: (current, total) => progress.add('$current/$total'),
      );

      expect(translatedChunks, ['Disc\ntrack01.mp3\ntrack02.mp3']);
      expect(localSourceLanguages, ['ja', 'ja', 'ja']);
      expect(progress, ['1/1']);
      expect(result.names, ['Disc', 'track01.mp3', 'track02.mp3']);
      expect(result.translations, {
        'Disc': 'translated:Disc',
        'track01.mp3': 'translated:track01.mp3',
        'track02.mp3': 'translated:track02.mp3',
      });
    });

    test('translates explicit visible names and removes duplicates', () async {
      final translatedChunks = <String>[];
      final service = FileNameTranslationService(
        translate: (text, {sourceLang}) async {
          expect(sourceLang, isNull);
          translatedChunks.add(text);
          return text.split('\n').map((line) => 'translated:$line').join('\n');
        },
        delay: (_) async {},
      );

      final result = await service.translateNames(
        names: ['track01.mp3', 'track02.mp3', 'track01.mp3'],
        maxChunkSize: 100,
      );

      expect(translatedChunks, ['track01.mp3\ntrack02.mp3']);
      expect(result.names, ['track01.mp3', 'track02.mp3']);
      expect(result.translations, {
        'track01.mp3': 'translated:track01.mp3',
        'track02.mp3': 'translated:track02.mp3',
      });
    });

    test('falls back to original chunk on translation failure', () async {
      final chunkErrors = <String>[];
      final service = FileNameTranslationService(
        translate: (text, {sourceLang}) async {
          if (text.contains('bad')) {
            throw StateError('failed');
          }
          return 'ok:$text';
        },
        delay: (_) async {},
      );

      final result = await service.translateFileTree(
        fileTree: [fileItem('good'), fileItem('bad')],
        maxChunkSize: 20,
        onChunkError: (index, error) {
          chunkErrors.add('$index:${error.runtimeType}');
        },
      );

      expect(chunkErrors, ['0:StateError']);
      expect(result.translations, {'good': 'good', 'bad': 'bad'});
    });

    test('keeps a whole chunk original when a response omits a line', () async {
      final service = FileNameTranslationService(
        translate: (text, {sourceLang}) async => 'translated:first',
        delay: (_) async {},
      );

      final result = await service.translateNames(
        names: ['first', 'second'],
        maxChunkSize: 100,
      );

      expect(result.translations, {'first': 'first', 'second': 'second'});
    });

    for (final invalidResponse in {
      'missing line': 'A',
      'extra line': 'A\nB\nextra',
      'empty line': 'A\n',
    }.entries) {
      test('${invalidResponse.key} does not shift later names', () async {
        final errors = <int>[];
        final service = FileNameTranslationService(
          translate: (text, {sourceLang}) async =>
              text == 'a\nb' ? invalidResponse.value : 'C\r\nD\r\n',
          delay: (_) async {},
        );
        final result = await service.translateNames(
          names: ['a', 'b', 'c', 'd'],
          maxChunkSize: 3,
          onChunkError: (index, error) => errors.add(index),
        );
        expect(errors, [0]);
        expect(result.translations, {'a': 'a', 'b': 'b', 'c': 'C', 'd': 'D'});
      });
    }

    test('blank translated names keep their chunk original', () async {
      final result = await FileNameTranslationService(
        translate: (text, {sourceLang}) async => 'A\n \nC',
        delay: (_) async {},
      ).translateNames(names: ['a', 'b', 'c']);
      expect(result.translations, {'a': 'a', 'b': 'b', 'c': 'c'});
    });

    test('delays only between multiple chunks', () async {
      final delays = <Duration>[];
      final service = FileNameTranslationService(
        translate: (text, {sourceLang}) async => text,
        delay: (duration) async {
          delays.add(duration);
        },
      );

      await service.translateFileTree(
        fileTree: [fileItem('aaaa'), fileItem('bbbb'), fileItem('cccc')],
        maxChunkSize: 4,
        throttleDelay: const Duration(milliseconds: 12),
      );

      expect(delays, [
        const Duration(milliseconds: 12),
        const Duration(milliseconds: 12),
      ]);
    });
  });
}
