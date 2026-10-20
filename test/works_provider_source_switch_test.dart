import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/providers/audio_source_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart'
    show kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/providers/subtitle_library_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Request {
  _Request(this.source, this.cancelToken);

  final AudioSource source;
  final CancelToken? cancelToken;
  final response = Completer<Map<String, dynamic>>();
}

class _DeferredApi extends KikoeruApiService {
  final requests = <_Request>[];

  @override
  Future<Map<String, dynamic>> getWorks({
    int page = 1,
    int pageSize = 40,
    AudioSource source = AudioSource.asmrOne,
    String? order,
    String? sort,
    int? subtitle,
    int? seed,
    CancelToken? cancelToken,
  }) {
    final request = _Request(source, cancelToken);
    requests.add(request);
    return request.response.future;
  }
}

class _EmptySubtitleLibrary extends SubtitleLibraryNotifier {
  @override
  Future<void> refresh() async {}
}

Map<String, dynamic> _response(int workId) => {
  'works': [
    {'id': workId, 'title': 'Work $workId'},
  ],
  'pagination': {'currentPage': 1, 'pageSize': 40, 'totalCount': 1},
};

void main() {
  test(
    'a late response from the previous source cannot replace JP results',
    () async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final api = _DeferredApi();
      final container = ProviderContainer(
        overrides: [
          kikoeruApiServiceProvider.overrideWithValue(api),
          subtitleLibraryProvider.overrideWith(
            (ref) => _EmptySubtitleLibrary(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final japaneseResultsApplied = Completer<void>();
      final subscription = container.listen(worksProvider, (_, state) {
        if (state.works.any((work) => work.id == -1726738) &&
            !japaneseResultsApplied.isCompleted) {
          japaneseResultsApplied.complete();
        }
      });
      addTearDown(subscription.close);

      final previousSourceRequest = container
          .read(worksProvider.notifier)
          .loadWorks(targetPage: 1, refresh: true, supersede: true);
      expect(api.requests, hasLength(1));
      expect(api.requests.single.source, AudioSource.asmrOne);

      await container
          .read(audioSourceProvider.notifier)
          .select(AudioSource.jpAsmr);
      expect(api.requests, hasLength(2));
      expect(api.requests.last.source, AudioSource.jpAsmr);
      expect(api.requests.first.cancelToken!.isCancelled, isTrue);

      api.requests.last.response.complete(_response(-1726738));
      await japaneseResultsApplied.future;
      api.requests.first.response.complete(_response(1726738));
      await previousSourceRequest;

      expect(container.read(worksProvider).works.map((work) => work.id), [
        -1726738,
      ]);
    },
  );
}
