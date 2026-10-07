import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/file_name_translation_controller.dart';

void main() {
  group('FileNameTranslationController', () {
    test('display names follow the page state and use cached values', () {
      final controller = FileNameTranslationController();
      controller.translations['track01.mp3'] = 'translated track';

      expect(
        controller.displayName('track01.mp3', showTranslation: false),
        'track01.mp3',
      );
      expect(
        controller.displayName('track01.mp3', showTranslation: true),
        'translated track',
      );
      expect(
        controller.displayName('track02.mp3', showTranslation: true),
        'track02.mp3',
      );
    });

    test('bulk translation ignores stale progress and completion', () {
      final controller = FileNameTranslationController();

      final first = controller.beginBulkTranslation('Preparing');
      expect(controller.isBulkTranslating, isTrue);
      expect(controller.progress, 'Preparing');

      final second = controller.beginBulkTranslation('Restarting');
      expect(
        controller.updateBulkProgress(first, 'Stale progress'),
        isFalse,
      );
      expect(controller.progress, 'Restarting');
      expect(
        controller.completeBulkTranslation(first, const {'old': 'stale'}),
        isFalse,
      );
      expect(controller.translations, isEmpty);

      expect(
        controller.updateBulkProgress(second, 'Translating 1/1'),
        isTrue,
      );
      expect(
        controller.completeBulkTranslation(second, const {'name': 'translated'}),
        isTrue,
      );
      expect(controller.isBulkTranslating, isFalse);
      expect(controller.progress, isEmpty);
      expect(controller.translations, {'name': 'translated'});
      expect(
        controller.displayName('name', showTranslation: false),
        'name',
      );
    });

    test('later visible-name batches merge into the existing cache', () {
      final controller = FileNameTranslationController();
      final first = controller.beginBulkTranslation('First tab');
      expect(
        controller.completeBulkTranslation(first, const {'one': 'uno'}),
        isTrue,
      );

      final second = controller.beginBulkTranslation('Second tab');
      expect(
        controller.completeBulkTranslation(second, const {'two': 'dos'}),
        isTrue,
      );
      expect(controller.translations, {'one': 'uno', 'two': 'dos'});
    });

    test('dispose invalidates an in-flight batch', () {
      final controller = FileNameTranslationController();
      final generation = controller.beginBulkTranslation('Preparing');
      controller.dispose();

      expect(
        controller.completeBulkTranslation(
          generation,
          const {'track01.mp3': 'translated track'},
        ),
        isFalse,
      );
      expect(controller.translations, isEmpty);
      expect(controller.isBulkTranslating, isFalse);
      expect(controller.progress, isEmpty);
    });
  });
}
