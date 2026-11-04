import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/user.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/services/playback_session_store.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_latest_request_test.dart' show ControlledPlayer;

const _host = 'https://example.invalid';

PlaybackSessionSnapshot _snapshot(String user, String id) =>
    PlaybackSessionSnapshot(
      queue: [
        AudioTrack(id: id, title: id, url: 'https://example.invalid/$id.mp3'),
      ],
      currentIndex: 0,
      position: Duration.zero,
      ownerKey: '$_host\n$user',
      markingQueueId: id,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'revoked auth hides old history before preferences finish committing',
    () async {
      SharedPreferences.setMockInitialValues({
        'server_host': _host,
        'current_user': '{"name":"alice"}',
        'audio_anonymous': true,
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final service = _HistoryService([
        _snapshot('alice', 'alice-queue'),
        _snapshot('anonymous', 'anonymous-queue'),
      ]);
      addTearDown(service.dispose);
      final container = ProviderContainer(
        overrides: [
          audioPlayerServiceProvider.overrideWithValue(service),
          authProvider.overrideWith((ref) => _Auth()),
        ],
      );
      addTearDown(container.dispose);
      final auth = container.read(authProvider.notifier) as _Auth;
      await auth.ready;
      auth.useUser(const User(name: 'alice'));
      final updates = Completer<List<PlaybackSessionSnapshot>>();
      final subscription = container.listen(historicalQueuesProvider, (
        _,
        next,
      ) {
        final queues = next.valueOrNull;
        if (queues?.length == 2 && !updates.isCompleted) {
          updates.complete(queues);
        }
      });
      addTearDown(subscription.close);

      expect(
        (await container.read(
          historicalQueuesProvider.future,
        )).single.queue.single.id,
        'alice-queue',
      );
      auth.useUser(null);

      expect(StorageService.getMap('current_user')?['name'], 'alice');
      expect(
        (await container.read(
          historicalQueuesProvider.future,
        )).single.queue.single.id,
        'anonymous-queue',
      );

      service.queues.add(_snapshot('anonymous', 'another-anonymous-queue'));
      service.publish();
      expect(
        (await updates.future.timeout(
          const Duration(seconds: 2),
        )).map((queue) => queue.ownerKey),
        everyElement('$_host\nanonymous'),
      );
    },
  );

  test('audio controller forwards historical queue clearing', () async {
    SharedPreferences.setMockInitialValues({
      'server_host': _host,
      'current_user': '{"name":"alice"}',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final snapshot = _snapshot('alice', 'alice-queue');
    final service = _HistoryService([snapshot])..clearResult = true;
    addTearDown(service.dispose);
    final container = ProviderContainer(
      overrides: [audioPlayerServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    final result = await container
        .read(audioPlayerControllerProvider.notifier)
        .clearHistoricalQueue(snapshot);

    expect(result, isTrue);
    expect(service.clearedSnapshot, same(snapshot));
  });
}

class _Auth extends AuthNotifier {
  _Auth() : super(KikoeruApiService());

  void useUser(User? user) {
    state = AuthState(
      host: '$_host/',
      currentUser: user,
      isLoggedIn: user != null,
    );
  }

  @override
  Future<void> enterAnonymous({String? host}) async {}
}

class _HistoryService extends AudioPlayerService {
  _HistoryService(this.queues) : super.forTesting(ControlledPlayer());

  final List<PlaybackSessionSnapshot> queues;
  final _changes = StreamController<void>.broadcast();
  PlaybackSessionSnapshot? clearedSnapshot;
  bool clearResult = false;

  @override
  List<PlaybackSessionSnapshot> get historicalQueues =>
      queues.where((queue) => queue.ownerKey == '$_host\nalice').toList();

  @override
  List<PlaybackSessionSnapshot> historicalQueuesForOwner(String? ownerKey) =>
      queues.where((queue) => queue.ownerKey == ownerKey).toList();

  @override
  Stream<List<PlaybackSessionSnapshot>> get historicalQueuesStream =>
      _changes.stream.map((_) => historicalQueues);

  @override
  Stream<List<PlaybackSessionSnapshot>> historicalQueuesForOwnerStream(
    String? ownerKey,
  ) => _changes.stream.map((_) => historicalQueuesForOwner(ownerKey));

  @override
  Future<bool> clearHistoricalQueue(PlaybackSessionSnapshot snapshot) async {
    clearedSnapshot = snapshot;
    return clearResult;
  }

  void publish() => _changes.add(null);

  @override
  Future<void> dispose() async {
    await _changes.close();
    await super.dispose();
  }
}
