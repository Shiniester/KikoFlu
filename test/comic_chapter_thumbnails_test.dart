import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_chapter_thumbnails.dart';

void main() {
  test(
    'chapter thumbnails sample the start, middle and end without repeats',
    () {
      expect(comicChapterThumbnailIndices(0), isEmpty);
      expect(comicChapterThumbnailIndices(1), [0]);
      expect(comicChapterThumbnailIndices(2), [0, 1]);
      expect(comicChapterThumbnailIndices(3), [0, 1, 2]);
      expect(comicChapterThumbnailIndices(8), [0, 3, 7]);
      expect(comicChapterThumbnailIndices(101), [0, 50, 100]);
    },
  );
}
