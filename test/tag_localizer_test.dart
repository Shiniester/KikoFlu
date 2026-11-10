import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/utils/tag_localizer.dart';

void main() {
  const names = {
    'zh-CN': '耳搔',
    'zh-TW': '耳搔聲',
    'en': 'Ear cleaning',
    'ja': '耳かき',
  };
  test(
    'source tag translations follow the application language and script',
    () {
      for (final (locale, expected) in [
        (const Locale('zh', 'CN'), '耳搔'),
        (
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
          '耳搔聲',
        ),
        (const Locale('zh', 'HK'), '耳搔聲'),
        (const Locale('en', 'US'), 'Ear cleaning'),
        (const Locale('ja'), '耳かき'),
      ]) {
        expect(
          TagLocalizer.localize(-1, '耳かき', locale, names: names),
          expected,
        );
      }
    },
  );
  test('missing or blank translations use the source name', () {
    expect(
      TagLocalizer.localize(-1, '耳かき', const Locale('de'), names: names),
      '耳かき',
    );
    expect(TagLocalizer.localize(-1, '耳かき', const Locale('en')), '耳かき');
    expect(
      TagLocalizer.localize(
        -1,
        '耳かき',
        const Locale('en'),
        names: const {'en-US': '  '},
      ),
      '耳かき',
    );
  });
  test('old tag metadata remains readable without translated names', () {
    final tag = Tag.fromJson(const {'id': 68, 'name': '耳かき'});
    expect(tag.names, isEmpty);
    expect(Tag.fromJson(tag.toJson()), tag);
  });
  test('conflicting names for the same language keep the source name', () {
    expect(
      TagLocalizer.localize(
        -1,
        '耳かき',
        const Locale('zh'),
        names: {'zh-CN': '耳搔', 'zh-Hans': '采耳'},
      ),
      '耳かき',
    );
  });
}
