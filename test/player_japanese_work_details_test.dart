import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/player_work_details_provider.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends KikoeruApiService {
  final requestedWorkIds = <int>[];

  @override
  Future<Map<String, dynamic>> getWork(
    int id, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    requestedWorkIds.add(id);
    return {'id': id, 'title': 'Eara work', 'source_id': 'RJ01707048'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('anonymous Japanese playback loads the work and file tree', () async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    const track = AudioTrack(
      id: 'jp-audio',
      title: 'Track',
      url: 'https://media.example/track.m3u8',
      workId: -150867,
    );
    final api = _Api();
    final auth = AuthNotifier(api);
    await auth.ready;
    var treeRequests = 0;
    final container = ProviderContainer(
      overrides: [
        currentTrackProvider.overrideWith((ref) => Stream.value(track)),
        authProvider.overrideWith((ref) => auth),
        kikoeruApiServiceProvider.overrideWithValue(api),
        playbackLyricFileTreeLoaderProvider.overrideWithValue((track) async {
          treeRequests++;
          return [
            {'type': 'audio', 'title': 'Track', 'hash': 'jp-audio'},
          ];
        }),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(authProvider).isLoggedIn, isFalse);
    await container.read(currentTrackProvider.future);
    final details = await container.read(playerWorkDetailsProvider.future);

    expect(treeRequests, 1);
    expect(api.requestedWorkIds, [-150867]);
    expect(details?.work.title, 'Eara work');
    expect(details?.fileTree, hasLength(1));
    expect(details?.metadataError, isNull);
  });
}
