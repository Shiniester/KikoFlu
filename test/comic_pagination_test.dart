import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/comics/comic_models.dart';
import 'package:kikoeru_flutter/src/comics/comic_pagination.dart';

Comic _comic(String source, int index) =>
    Comic(source: source, id: '$index', title: '$source $index');

void main() {
  for (final pageSize in [20, 40, 60, 100]) {
    test(
      'cursor buffer supports comic page size $pageSize without prefetching',
      () async {
        final cursors = <String?>[];
        final buffer = ComicPageBuffer([
          ComicPageSource('a', (cursor) async {
            cursors.add(cursor);
            return cursor == null
                ? ComicResult(
                    List.generate(pageSize + 1, (i) => _comic('a', i)),
                    next: 'p2',
                  )
                : ComicResult([_comic('a', pageSize + 1)]);
          }),
        ]);

        final first = await buffer.page(1, pageSize);
        expect(first.items, hasLength(pageSize));
        expect(first.hasMore, isTrue);
        expect(cursors, [null]);
        final second = await buffer.page(2, pageSize);
        expect(second.items, hasLength(2));
        expect(cursors, [null, 'p2']);
      },
    );
  }

  test('cursor pages are assembled and previous pages use the cache', () async {
    final cursors = <String?>[];
    final buffer = ComicPageBuffer([
      ComicPageSource('a', (cursor) async {
        cursors.add(cursor);
        return switch (cursor) {
          null => ComicResult([_comic('a', 1), _comic('a', 2)], next: 'p2'),
          'p2' => ComicResult([_comic('a', 3), _comic('a', 4)], next: 'p3'),
          _ => ComicResult([_comic('a', 5)]),
        };
      }),
    ]);

    final first = await buffer.page(1, 3);
    expect(first.items.map((comic) => comic.id), ['1', '2', '3']);
    expect(first.hasMore, isTrue);
    final second = await buffer.page(2, 3);
    expect(second.items.map((comic) => comic.id), ['4', '5']);
    expect(second.hasMore, isFalse);
    final cachedFirst = await buffer.page(1, 3);
    expect(cachedFirst.items, first.items);
    expect(cachedFirst.hasMore, isTrue);
    expect(cursors, [null, 'p2', 'p3']);
  });

  test('merged pages remain round-robin as source cursors advance', () async {
    final buffer = ComicPageBuffer([
      ComicPageSource(
        'a',
        (cursor) async => cursor == null
            ? ComicResult([_comic('a', 1), _comic('a', 2)], next: 'a2')
            : ComicResult([_comic('a', 3), _comic('a', 4)]),
      ),
      ComicPageSource(
        'b',
        (cursor) async => cursor == null
            ? ComicResult([_comic('b', 1), _comic('b', 2)], next: 'b2')
            : ComicResult([_comic('b', 3)]),
      ),
    ]);

    final first = await buffer.page(1, 4);
    expect(first.items.map((comic) => comic.key), [
      _comic('a', 1).key,
      _comic('b', 1).key,
      _comic('a', 2).key,
      _comic('b', 2).key,
    ]);
    final second = await buffer.page(2, 4);
    expect(second.items.map((comic) => comic.key), [
      _comic('a', 3).key,
      _comic('b', 3).key,
      _comic('a', 4).key,
    ]);
    expect(second.hasMore, isFalse);
    expect((await buffer.page(1, 4)).items, first.items);
  });

  test(
    'a failed source retries without losing the current page buffer',
    () async {
      var firstSourceCalls = 0;
      var secondSourceCalls = 0;
      final buffer = ComicPageBuffer([
        ComicPageSource('a', (cursor) async {
          if (firstSourceCalls++ == 0) throw StateError('offline');
          return ComicResult([_comic('a', 1)]);
        }),
        ComicPageSource('b', (cursor) async {
          secondSourceCalls++;
          return ComicResult([_comic('b', 1), _comic('b', 2)]);
        }),
      ]);

      final partial = await buffer.page(1, 2);
      expect(partial.items.map((comic) => comic.key), [
        _comic('b', 1).key,
        _comic('b', 2).key,
      ]);
      expect(partial.errors.keys, ['a']);
      expect(partial.errors['a'], isA<StateError>());
      final retry = await buffer.page(1, 2, retryFailures: true);
      expect(retry.items.map((comic) => comic.key), [
        _comic('b', 1).key,
        _comic('b', 2).key,
      ]);
      expect(retry.errors, isEmpty);
      expect(firstSourceCalls, 2);
      expect(secondSourceCalls, 1);
      final next = await buffer.page(2, 2);
      expect(next.items.map((comic) => comic.key), [_comic('a', 1).key]);
    },
  );

  test(
    'a failed later page leaves cached pages available before retry',
    () async {
      var failThirdPage = true;
      final buffer = ComicPageBuffer([
        ComicPageSource('a', (cursor) async {
          if (cursor == null) {
            return ComicResult([_comic('a', 1), _comic('a', 2)], next: 'p2');
          }
          if (cursor == 'p2') {
            return ComicResult([_comic('a', 3), _comic('a', 4)], next: 'p3');
          }
          if (failThirdPage) {
            failThirdPage = false;
            throw StateError('temporary error');
          }
          return ComicResult([_comic('a', 5), _comic('a', 6)]);
        }),
      ]);

      expect((await buffer.page(1, 2)).items.map((comic) => comic.id), [
        '1',
        '2',
      ]);
      expect((await buffer.page(2, 2)).items.map((comic) => comic.id), [
        '3',
        '4',
      ]);
      final failedThird = await buffer.page(3, 2);
      expect(failedThird.items, isEmpty);
      expect(failedThird.errors.keys, ['a']);
      final firstAgain = await buffer.page(1, 2);
      expect(firstAgain.items.map((comic) => comic.id), ['1', '2']);
      expect(firstAgain.errors, isEmpty);
      final retry = await buffer.page(3, 2, retryFailures: true);
      expect(retry.items.map((comic) => comic.id), ['5', '6']);
      expect(retry.errors, isEmpty);
    },
  );
}
