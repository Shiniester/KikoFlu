import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/models/search_scope_session.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/models/work.dart';

void main() {
  final query = SearchQuery(
    scope: SearchScope.playlists,
    conditions: const [
      SearchCondition(id: 'keyword', type: SearchType.keyword, value: 'title'),
    ],
  );

  test(
    'source cache deduplicates works and merges metadata and memberships',
    () {
      final session = SearchScopeSession();
      session.add(
        query,
        'account-a',
        const ScopedSearchEntry(
          work: Work(id: 5, title: 'Work title'),
          playlistNames: ['First'],
        ),
      );
      session.add(
        query,
        'account-a',
        const ScopedSearchEntry(
          work: Work(
            id: 5,
            title: 'Work title',
            tags: [Tag(id: 1, name: 'Tag')],
          ),
          playlistNames: ['Second'],
        ),
      );

      final entries = session.entriesFor(query, 'account-a');
      expect(entries, hasLength(1));
      expect(entries.single.work.tags, hasLength(1));
      expect(entries.single.playlistNames, ['First', 'Second']);
    },
  );

  test('cache completion and entries are isolated by account', () {
    final session = SearchScopeSession();
    session.add(
      query,
      'account-a',
      const ScopedSearchEntry(work: Work(id: 1, title: 'Work title')),
    );
    session.markComplete(query, 'account-a');

    expect(session.isComplete(query, 'account-a'), isTrue);
    expect(session.isComplete(query, 'account-b'), isFalse);
    expect(session.entriesFor(query, 'account-b'), isEmpty);
  });
}
