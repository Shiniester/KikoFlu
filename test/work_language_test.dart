import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/work.dart';

Map<String, dynamic> _otherEdition(int id, String language) => {
  'id': id,
  'lang': language,
  'title': 'Edition $id',
  'source_id': 'RJ$id',
  'is_original': false,
  'source_type': 'RJ',
};

void main() {
  test(
    'language_editions resolves the current source ID and round-trips lang',
    () {
      final work = Work.fromJson({
        'id': 416817,
        'title': 'Chinese edition',
        'age_category_string': '全年龄',
        'source_id': 'RJ416817',
        'translation_info': const {'lang': null},
        'language_editions': const [
          {'workno': 'RJ416816', 'lang': 'JPN'},
          {'workno': 'RJ416817', 'lang': 'CHI_HANS'},
          {'workno': 'RJ416838', 'lang': 'CHI_HANT'},
          {'workno': 'RJ416840', 'lang': 'ENG'},
        ],
        'other_language_editions_in_db': [
          _otherEdition(416816, 'JPN'),
          _otherEdition(416838, 'CHI_HANT'),
        ],
      });

      expect(work.lang, 'CHI_HANS');
      expect(work.age, '全年龄');
      expect(work.otherLanguageEditions!.map((edition) => edition.id), [
        416816,
        416838,
      ]);
      expect(
        work.otherLanguageEditions!.any((edition) => edition.id == work.id),
        isFalse,
      );
      expect(work.toJson()['lang'], 'CHI_HANS');
      final decoded = jsonDecode(jsonEncode(work)) as Map<String, dynamic>;
      final roundTripped = Work.fromJson(decoded);
      expect(roundTripped.lang, 'CHI_HANS');
      expect(roundTripped.age, '全年龄');
      expect(work.copyWith().lang, 'CHI_HANS');
    },
  );

  test('direct and translation languages precede edition-list inference', () {
    final direct = Work.fromJson(const {
      'id': 416817,
      'title': 'Direct language',
      'source_id': 'RJ416817',
      'lang': 'JPN',
      'translation_info': {'lang': 'CHI_HANT'},
      'language_editions': [
        {'workno': 'RJ416817', 'lang': 'CHI_HANS'},
      ],
    });
    final translated = Work.fromJson(const {
      'id': 416817,
      'title': 'Translation language',
      'source_id': 'RJ416817',
      'translation_info': {'lang': 'CHI_HANT'},
      'language_editions': [
        {'workno': 'RJ416817', 'lang': 'CHI_HANS'},
      ],
    });

    expect(direct.lang, 'JPN');
    expect(translated.lang, 'CHI_HANT');
  });

  test(
    'RJ work number fallback handles zero padding only without source ID',
    () {
      final inferred = Work.fromJson(const {
        'id': 416817,
        'title': 'Inferred by RJ ID',
        'language_editions': [
          {'workno': 'RJ00416817', 'lang': 'CHI_HANS'},
        ],
      });
      final mismatchedSource = Work.fromJson(const {
        'id': 416817,
        'title': 'Source ID must match',
        'source_id': 'RJ999999',
        'language_editions': [
          {'workno': 'RJ416817', 'lang': 'CHI_HANS'},
        ],
      });

      expect(inferred.lang, 'CHI_HANS');
      expect(mismatchedSource.lang, isNull);
    },
  );
}
