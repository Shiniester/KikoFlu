import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/providers/audio_source_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart'
    show kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/providers/search_result_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart'
    show blockedItemsBySourceProvider, blockedItemsProvider;
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FixedAudioSourceNotifier extends AudioSourceNotifier {
  _FixedAudioSourceNotifier(AudioSource source) {
    state = source;
  }
}

class _SearchApi extends KikoeruApiService {
  AudioSource? requestedSource;

  @override
  Future<Map<String, dynamic>> searchWorks({
    required String keyword,
    int page = 1,
    int pageSize = 40,
    AudioSource source = AudioSource.asmrOne,
    List<SearchCondition> conditions = const [],
    String? order,
    String? sort,
    int? subtitle,
    int? seed,
    bool includeTranslationWorks = true,
    CancelToken? cancelToken,
  }) async {
    requestedSource = source;
    return {
      'works': [
        {
          'id': -1,
          'title': 'ASMR.ONE blocked name',
          'tags': [
            {'id': 1, 'name': 'Shared'},
          ],
        },
        {
          'id': -2,
          'title': 'JP blocked name',
          'tags': [
            {'id': 2, 'name': 'Japanese only'},
          ],
        },
        {'id': -3, 'title': 'Available'},
      ],
      'pagination': {'totalCount': 3},
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  test(
    'source block lists persist separately and keep legacy ASMR values',
    () async {
      SharedPreferences.setMockInitialValues({
        'blocked_tags': ['Shared'],
        'blocked_cvs': ['ASMR voice'],
        'blocked_circles': ['ASMR circle'],
        'blocked_jp_asmr_tags': ['Japanese only'],
        'blocked_jp_asmr_cvs': ['JP voice'],
        'blocked_jp_asmr_circles': ['JP circle'],
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(blockedItemsProvider.notifier),
        same(
          container.read(
            blockedItemsBySourceProvider(AudioSource.asmrOne).notifier,
          ),
        ),
      );

      final asmr = container.read(blockedItemsProvider.notifier);
      final japanese = container.read(
        blockedItemsBySourceProvider(AudioSource.jpAsmr).notifier,
      );

      await Future.wait([
        asmr.addTag('ASMR added'),
        japanese.addTag('JP added'),
      ]);
      await japanese.removeCv('JP voice');

      expect(container.read(blockedItemsProvider).tags, [
        'Shared',
        'ASMR added',
      ]);
      expect(container.read(blockedItemsProvider).cvs, ['ASMR voice']);
      expect(container.read(blockedItemsProvider).circles, ['ASMR circle']);
      expect(
        container.read(blockedItemsBySourceProvider(AudioSource.jpAsmr)).tags,
        ['Japanese only', 'JP added'],
      );
      expect(
        container.read(blockedItemsBySourceProvider(AudioSource.jpAsmr)).cvs,
        isEmpty,
      );
      expect(
        container
            .read(blockedItemsBySourceProvider(AudioSource.jpAsmr))
            .circles,
        ['JP circle'],
      );

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getStringList('blocked_tags'), [
        'Shared',
        'ASMR added',
      ]);
      expect(preferences.getStringList('blocked_jp_asmr_tags'), [
        'Japanese only',
        'JP added',
      ]);
      expect(preferences.getStringList('blocked_cvs'), ['ASMR voice']);
      expect(preferences.getStringList('blocked_jp_asmr_cvs'), isEmpty);

      final restoredContainer = ProviderContainer();
      addTearDown(restoredContainer.dispose);
      await Future.wait([
        restoredContainer
            .read(blockedItemsProvider.notifier)
            .addTag('ASMR added'),
        restoredContainer
            .read(blockedItemsBySourceProvider(AudioSource.jpAsmr).notifier)
            .addTag('JP added'),
      ]);
      expect(restoredContainer.read(blockedItemsProvider).tags, [
        'Shared',
        'ASMR added',
      ]);
      expect(
        restoredContainer
            .read(blockedItemsBySourceProvider(AudioSource.jpAsmr))
            .tags,
        ['Japanese only', 'JP added'],
      );
    },
  );

  test(
    'a pinned JP search uses JP blocks while ASMR.ONE has the same tag',
    () async {
      SharedPreferences.setMockInitialValues({
        'blocked_tags': ['Shared'],
        'blocked_jp_asmr_tags': ['Japanese only'],
      });
      final api = _SearchApi();
      final container = ProviderContainer(
        overrides: [
          kikoeruApiServiceProvider.overrideWithValue(api),
          audioSourceProvider.overrideWith(
            (ref) => _FixedAudioSourceNotifier(AudioSource.asmrOne),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(blockedItemsProvider.notifier).addTag('Shared');
      await container
          .read(blockedItemsBySourceProvider(AudioSource.jpAsmr).notifier)
          .addTag('Japanese only');

      final notifier = container.read(searchResultProvider.notifier);
      await notifier.initializeSearch(
        keyword: 'query',
        searchParams: {'source': AudioSource.jpAsmr.name},
      );

      expect(api.requestedSource, AudioSource.jpAsmr);
      expect(
        container.read(searchResultProvider).works.map((work) => work.id),
        [-1, -3],
      );

      await container
          .read(blockedItemsBySourceProvider(AudioSource.jpAsmr).notifier)
          .removeTag('Japanese only');

      expect(
        container.read(searchResultProvider).works.map((work) => work.id),
        [-1, -2, -3],
      );
    },
  );
}
