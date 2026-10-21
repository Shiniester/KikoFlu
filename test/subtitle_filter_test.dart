import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/utils/subtitle_filter.dart';

const _onlineSubtitleWork = Work(
  id: 1,
  title: 'online subtitle',
  hasSubtitle: true,
);

const _localSubtitleWork = Work(
  id: 2,
  title: 'local subtitle',
  hasSubtitle: false,
);

const _noSubtitleWork = Work(id: 3, title: 'no subtitle', hasSubtitle: false);

void main() {
  test('subtitle filter cycles through available states', () {
    expect(SubtitleFilterMode.all.next, SubtitleFilterMode.withSubtitles);
    expect(SubtitleFilterMode.withSubtitles.next, SubtitleFilterMode.all);
  });

  test('legacy without-subtitles value falls back to all works', () {
    expect(SubtitleFilterMode.fromValue(2), SubtitleFilterMode.all);
  });

  test('only includes works with online subtitles', () {
    expect(
      filterWorksBySubtitleMode([
        _onlineSubtitleWork,
        _localSubtitleWork,
        _noSubtitleWork,
        const Work(id: 4, title: 'unknown subtitle status'),
      ], SubtitleFilterMode.withSubtitles.value),
      [_onlineSubtitleWork],
    );
  });

  test('filters works by subtitle mode', () {
    const works = [_onlineSubtitleWork, _localSubtitleWork, _noSubtitleWork];

    expect(
      filterWorksBySubtitleMode(
        works,
        SubtitleFilterMode.all.value,
      ).map((work) => work.id),
      [1, 2, 3],
    );
    expect(
      filterWorksBySubtitleMode(
        works,
        SubtitleFilterMode.withSubtitles.value,
      ).map((work) => work.id),
      [1],
    );
    expect(filterWorksBySubtitleMode(works, 2).map((work) => work.id), [
      1,
      2,
      3,
    ]);
  });
}
