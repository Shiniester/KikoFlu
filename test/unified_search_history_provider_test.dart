import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/src/providers/unified_search_history_provider.dart';

const _audioAsmrOne = UnifiedSearchHistoryContext(
  contentType: 'audio',
  entryScope: 'global-works',
  source: 'asmrOne',
);
const _audioJpAsmr = UnifiedSearchHistoryContext(
  contentType: 'audio',
  entryScope: 'global-works',
  source: 'jpAsmr',
);
const _audioFavorites = UnifiedSearchHistoryContext(
  contentType: 'audio',
  entryScope: 'favorites',
  source: 'asmrOne',
);
const _videoDirectory = UnifiedSearchHistoryContext(
  contentType: 'video',
  entryScope: 'source-directory',
  source: 'legacy-unknown',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  UnifiedSearchHistoryNotifier notifier() =>
      container.read(unifiedSearchHistoryProvider.notifier);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  test('isolates contexts and scopes removal and clearing', () async {
    await notifier().load();
    const query = {'keyword': 'same query'};
    final asmrId = await notifier().addOrReplace(_audioAsmrOne, query);
    await notifier().addOrReplace(_audioJpAsmr, query);
    await notifier().addOrReplace(_audioFavorites, query);
    await notifier().addOrReplace(_videoDirectory, query);

    expect(notifier().itemsFor(_audioAsmrOne), hasLength(1));
    expect(notifier().itemsFor(_audioJpAsmr), hasLength(1));
    expect(notifier().itemsFor(_audioFavorites), hasLength(1));
    expect(notifier().itemsFor(_videoDirectory), hasLength(1));

    await notifier().remove(_audioAsmrOne, asmrId);
    await notifier().clear(_videoDirectory);

    expect(notifier().itemsFor(_audioAsmrOne), isEmpty);
    expect(notifier().itemsFor(_videoDirectory), isEmpty);
    expect(notifier().itemsFor(_audioJpAsmr), hasLength(1));
    expect(notifier().itemsFor(_audioFavorites), hasLength(1));
  });

  test(
    'restores complete JSON payloads and deduplicates key order variants',
    () async {
      await notifier().load();
      final payload = <String, Object?>{
        'keyword': 'voice sample',
        'conditions': [
          {
            'type': 'tag',
            'value': 'soft voice',
            'sourcePath': '/tags/voice',
            'isExclude': false,
          },
        ],
        'sources': ['asmrOne', 'jpAsmr'],
        'sort': {'field': 'rating', 'direction': 'descending'},
      };
      final id = await notifier().addOrReplace(_audioJpAsmr, payload);

      container.dispose();
      container = ProviderContainer();
      await notifier().load();

      expect(notifier().itemsFor(_audioJpAsmr).single.payload, payload);
      await notifier().addOrReplace(_audioJpAsmr, {'keyword': 'newer query'});
      final duplicateId = await notifier().addOrReplace(_audioJpAsmr, {
        'sort': {'direction': 'descending', 'field': 'rating'},
        'sources': ['asmrOne', 'jpAsmr'],
        'conditions': [
          {
            'isExclude': false,
            'sourcePath': '/tags/voice',
            'value': 'soft voice',
            'type': 'tag',
          },
        ],
        'keyword': 'voice sample',
      });

      expect(duplicateId, id);
      expect(notifier().itemsFor(_audioJpAsmr), hasLength(2));
      expect(notifier().itemsFor(_audioJpAsmr).first.id, id);
    },
  );

  test(
    'replaces the active record and creates a new record after replay edits',
    () async {
      await notifier().load();
      final originalId = await notifier().addOrReplace(_audioAsmrOne, {
        'keyword': 'original',
        'filters': <String>[],
      });
      final replacedId = await notifier().addOrReplace(_audioAsmrOne, {
        'keyword': 'original',
        'filters': ['new filter'],
      }, id: originalId);
      final replayEditId = await notifier().addOrReplace(_audioAsmrOne, {
        'keyword': 'original',
        'filters': ['replay edit'],
      });

      expect(replacedId, originalId);
      expect(replayEditId, isNot(originalId));
      expect(notifier().itemsFor(_audioAsmrOne), hasLength(2));
      expect(notifier().itemsFor(_audioAsmrOne).first.id, replayEditId);
      expect(notifier().itemsFor(_audioAsmrOne).last.payload['filters'], [
        'new filter',
      ]);
    },
  );

  test(
    'replay edits do not replace existing history when filters are reverted',
    () async {
      await notifier().load();
      const original = {'keyword': 'voice', 'filters': <String>[]};
      const existing = {
        'keyword': 'voice',
        'filters': ['existing'],
      };
      await notifier().addOrReplace(_audioAsmrOne, original);
      await notifier().addOrReplace(_audioAsmrOne, existing);
      final session = UnifiedSearchHistorySession(notifier());

      await session.replay(context: _audioAsmrOne, payload: original);
      await session.update(_audioAsmrOne, original);
      await session.update(_audioAsmrOne, existing);
      await session.update(_audioAsmrOne, {
        'keyword': 'voice',
        'filters': ['new'],
      });
      expect(notifier().itemsFor(_audioAsmrOne), hasLength(3));

      await session.update(_audioAsmrOne, original);
      expect(notifier().itemsFor(_audioAsmrOne), hasLength(2));
      expect(
        notifier().itemsFor(_audioAsmrOne).map((entry) => entry.payload),
        containsAll([original, existing]),
      );

      await session.update(_audioAsmrOne, {
        'keyword': 'voice',
        'filters': ['another'],
      });
      expect(notifier().itemsFor(_audioAsmrOne), hasLength(3));
      expect(
        notifier().itemsFor(_audioAsmrOne).map((entry) => entry.payload),
        containsAll([original, existing]),
      );
    },
  );

  test(
    'repeated submissions and filter changes keep earlier records',
    () async {
      await notifier().load();
      const original = {'keyword': 'voice', 'filters': <String>[]};
      const savedFilter = {
        'keyword': 'voice',
        'filters': ['saved'],
      };
      await notifier().addOrReplace(_audioAsmrOne, original);
      await notifier().addOrReplace(_audioAsmrOne, savedFilter);
      final session = UnifiedSearchHistorySession(notifier());

      await session.submit(_audioAsmrOne, original);
      await session.update(_audioAsmrOne, {
        'keyword': 'voice',
        'filters': ['new'],
      });
      expect(notifier().itemsFor(_audioAsmrOne), hasLength(3));
      expect(
        notifier().itemsFor(_audioAsmrOne).map((entry) => entry.payload),
        containsAll([original, savedFilter]),
      );

      await session.update(_audioAsmrOne, savedFilter);
      expect(notifier().itemsFor(_audioAsmrOne), hasLength(2));
      await session.update(_audioAsmrOne, {
        'keyword': 'voice',
        'filters': ['another'],
      });
      expect(notifier().itemsFor(_audioAsmrOne), hasLength(3));
      expect(
        notifier().itemsFor(_audioAsmrOne).map((entry) => entry.payload),
        containsAll([original, savedFilter]),
      );
    },
  );

  test('replaying the oldest entry keeps it when a context is full', () async {
    await notifier().load();
    for (var index = 0; index < 20; index++) {
      await notifier().addOrReplace(_audioAsmrOne, {'keyword': 'query $index'});
    }
    final original = notifier().itemsFor(_audioAsmrOne).last;
    final session = UnifiedSearchHistorySession(notifier());

    await session.replay(
      context: _audioAsmrOne,
      payload: original.payload,
      entry: original,
    );
    await session.update(_audioAsmrOne, {
      'keyword': 'query 0',
      'filters': ['new'],
    });

    final entries = notifier().itemsFor(_audioAsmrOne);
    expect(entries, hasLength(20));
    expect(entries.any((entry) => entry.id == original.id), isTrue);
    expect(entries.first.payload['filters'], ['new']);
  });

  test(
    'serializes session updates across contexts and preserves replayed history',
    () async {
      await notifier().load();
      final keptId = await notifier().addOrReplace(_audioAsmrOne, {
        'keyword': 'keep in source context',
      });
      final session = UnifiedSearchHistorySession(notifier());

      final submit = session.submit(_audioAsmrOne, {
        'keyword': 'single source',
        'sources': ['asmrOne'],
      });
      final update = session.update(_audioJpAsmr, {
        'keyword': 'combined sources',
        'sources': ['asmrOne', 'jpAsmr'],
      });
      await Future.wait([submit, update]);

      expect(notifier().itemsFor(_audioAsmrOne).single.id, keptId);
      final movedEntry = notifier().itemsFor(_audioJpAsmr).single;
      expect(movedEntry.payload['sources'], ['asmrOne', 'jpAsmr']);

      final replay = session.replay();
      final replayUpdate = session.update(_audioJpAsmr, {
        'keyword': 'combined sources',
        'sources': ['asmrOne', 'jpAsmr'],
        'sort': 'newest',
      });
      await Future.wait([replay, replayUpdate]);

      final entries = notifier().itemsFor(_audioJpAsmr);
      expect(entries, hasLength(2));
      expect(entries.first.id, isNot(movedEntry.id));
      expect(entries.last.id, movedEntry.id);
      expect(entries.first.payload['sort'], 'newest');
      expect(notifier().itemsFor(_audioAsmrOne).single.id, keptId);
    },
  );

  test(
    'migrates audio and video legacy data without deleting old keys',
    () async {
      final legacyAudio = [
        {
          'id': 'legacy-jp',
          'keyword': 'jp search',
          'displayText': 'Tag: voice',
          'timestamp': '2026-10-30T10:00:00.000',
          'searchParams': {
            'keyword': 'jp search',
            'source': 'jpAsmr',
            'conditions': [
              {
                'searchType': 'tag',
                'value': 'voice',
                'sourcePath': '/source/tags/voice',
              },
            ],
          },
        },
        {
          'id': 'legacy-default',
          'keyword': 'default search',
          'displayText': 'keyword: default search',
          'timestamp': '2026-10-29T10:00:00.000',
          'searchParams': {'keyword': 'default search'},
        },
      ];
      SharedPreferences.setMockInitialValues({
        'search_history': jsonEncode(legacyAudio),
        'video_search_history': ['video legacy query'],
      });
      container.dispose();
      container = ProviderContainer();

      final newVideoSearch = notifier().addOrReplace(
        const UnifiedSearchHistoryContext(
          contentType: 'video',
          entryScope: 'source-directory',
          source: 'missav',
        ),
        {'keyword': 'new video query'},
      );
      await Future.wait([notifier().load(), newVideoSearch]);

      final jpEntry = notifier().itemsFor(_audioJpAsmr).single;
      expect(jpEntry.payload, legacyAudio.first);
      expect(
        (jpEntry.payload['searchParams'] as Map)['conditions'],
        (legacyAudio.first['searchParams'] as Map)['conditions'],
      );
      expect(
        notifier().itemsFor(_audioAsmrOne).single.payload,
        legacyAudio.last,
      );

      final legacyVideo = notifier().itemsFor(_videoDirectory).single;
      expect(legacyVideo.payload, {
        'keyword': 'video legacy query',
        'legacy': true,
      });
      expect(
        notifier().itemsFor(
          const UnifiedSearchHistoryContext(
            contentType: 'video',
            entryScope: 'favorites',
            source: 'legacy-unknown',
          ),
        ),
        isEmpty,
      );

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('search_history'), jsonEncode(legacyAudio));
      expect(preferences.getStringList('video_search_history'), [
        'video legacy query',
      ]);
      final migratedStore =
          jsonDecode(
                preferences.getString(
                  UnifiedSearchHistoryNotifier.preferenceKey,
                )!,
              )
              as Map<String, dynamic>;
      expect(migratedStore['legacyMigrationComplete'], isTrue);

      await notifier().clear(_audioJpAsmr);
      expect(notifier().itemsFor(_audioJpAsmr), isEmpty);
      expect(notifier().itemsFor(_audioAsmrOne), hasLength(1));
      expect(notifier().itemsFor(_videoDirectory), hasLength(1));
    },
  );

  test(
    'cleared video history does not return when old audio data is invalid',
    () async {
      SharedPreferences.setMockInitialValues({
        'search_history': '{invalid audio history',
        'video_search_history': ['old video query'],
      });
      container.dispose();
      container = ProviderContainer();
      await notifier().load();
      expect(notifier().itemsFor(_videoDirectory), hasLength(1));

      await notifier().clear(_videoDirectory);
      container.dispose();
      container = ProviderContainer();
      await notifier().load();

      expect(notifier().itemsFor(_videoDirectory), isEmpty);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('search_history'), '{invalid audio history');
    },
  );

  test('keeps at most twenty recent entries in each context', () async {
    await notifier().load();
    for (var index = 0; index < 21; index++) {
      await notifier().addOrReplace(_audioAsmrOne, {'keyword': 'query $index'});
    }

    final items = notifier().itemsFor(_audioAsmrOne);
    expect(items, hasLength(UnifiedSearchHistoryNotifier.maxItemsPerContext));
    expect(items.first.payload['keyword'], 'query 20');
    expect(items.last.payload['keyword'], 'query 1');
  });

  test('does not overwrite an unreadable unified store', () async {
    const unreadableStore = '{invalid JSON';
    SharedPreferences.setMockInitialValues({
      UnifiedSearchHistoryNotifier.preferenceKey: unreadableStore,
    });
    container.dispose();
    container = ProviderContainer();

    await notifier().addOrReplace(_audioAsmrOne, {'keyword': 'in memory'});

    expect(
      notifier().itemsFor(_audioAsmrOne).single.payload['keyword'],
      'in memory',
    );
    expect(notifier().canPersist, isFalse);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(UnifiedSearchHistoryNotifier.preferenceKey),
      unreadableStore,
    );
  });
}
