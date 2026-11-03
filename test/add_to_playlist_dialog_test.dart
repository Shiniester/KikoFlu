import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart'
    show kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/providers/automatic_work_marking_provider.dart';
import 'package:kikoeru_flutter/src/services/automatic_work_marking_service.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/widgets/add_to_playlist_dialog.dart';

class _PlaylistApi extends KikoeruApiService {
  final addResult = Completer<Map<String, dynamic>>();
  int addCalls = 0;

  @override
  Future<Map<String, dynamic>> getUserPlaylists({
    int page = 1,
    int pageSize = 20,
    String filterBy = 'all',
    CancelToken? cancelToken,
  }) async => {
    'playlists': [
      {
        'id': 'playlist-1',
        'user_name': 'alice',
        'privacy': 2,
        'name': 'Playlist',
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> getPlaylistWorks({
    required String playlistId,
    int page = 1,
    int pageSize = 12,
    CancelToken? cancelToken,
  }) async {
    return {'works': <dynamic>[]};
  }

  @override
  Future<Map<String, dynamic>> addWorksToPlaylist({
    required String playlistId,
    required List<String> works,
  }) {
    addCalls++;
    return addResult.future;
  }
}

class _RecordingMarkingService extends AutomaticWorkMarkingService {
  _RecordingMarkingService(String? Function() account)
    : super(
        account: account,
        fetchProgress: (_, _) async => null,
        writeProgress: (_, _) async {},
        persist: (_) async {},
        onChanged: () {},
        onConflict: () {},
        onSynced: () {},
        onError: (_) {},
      );

  final addedWorkIds = <int>[];

  @override
  Future<void> addedToPlaylist(int id) async {
    addedWorkIds.add(id);
  }
}

Future<void> _openDialog(
  WidgetTester tester, {
  required _PlaylistApi api,
  required _RecordingMarkingService marking,
}) async {
  tester.view
    ..physicalSize = const Size(480, 800)
    ..devicePixelRatio = 1;
  addTearDown(() {
    tester.view
      ..resetPhysicalSize()
      ..resetDevicePixelRatio();
  });
  addTearDown(api.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        kikoeruApiServiceProvider.overrideWithValue(api),
        automaticWorkMarkingProvider.overrideWithValue(marking),
      ],
      child: MaterialApp(
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  AddToPlaylistDialog.show(
                    context: context,
                    workId: 42,
                    workTitle: 'Work',
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();

  expect(find.byType(AddToPlaylistDialog), findsOneWidget);
  expect(find.text('Playlist'), findsOneWidget);
}

Future<void> _startAdd(WidgetTester tester, _PlaylistApi api) async {
  await tester.tap(find.text('Playlist'));
  await tester.pump();
  expect(api.addCalls, 1);
}

Future<void> _dismissSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(20, 20));
  await tester.pumpAndSettle();
  expect(find.byType(AddToPlaylistDialog), findsNothing);
}

void main() {
  testWidgets('marks a successfully added work after its sheet is dismissed', (
    tester,
  ) async {
    final api = _PlaylistApi();
    final marking = _RecordingMarkingService(() => 'server/alice');
    await _openDialog(tester, api: api, marking: marking);

    await _startAdd(tester, api);
    await _dismissSheet(tester);
    api.addResult.complete({});
    await tester.pump();

    expect(marking.addedWorkIds, [42]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('does not mark a work when adding it fails', (tester) async {
    final api = _PlaylistApi();
    final marking = _RecordingMarkingService(() => 'server/alice');
    await _openDialog(tester, api: api, marking: marking);

    await _startAdd(tester, api);
    api.addResult.completeError(StateError('add failed'));
    await tester.pump();

    expect(marking.addedWorkIds, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('does not mark an old account after the account changes', (
    tester,
  ) async {
    final api = _PlaylistApi();
    var account = 'server/alice';
    final marking = _RecordingMarkingService(() => account);
    await _openDialog(tester, api: api, marking: marking);

    await _startAdd(tester, api);
    await _dismissSheet(tester);
    account = 'server/bob';
    api.addResult.complete({});
    await tester.pump();

    expect(marking.addedWorkIds, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
