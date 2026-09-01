import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/playback_diagnostic_event.dart';
import 'package:kikoeru_flutter/src/performance/performance_fixture_manifest.dart';

void main() {
  const hash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  test('parses strict schema-2 fixture and exposes report-safe fields', () {
    final manifest = PerformanceFixtureManifest.fromJson(const {
      'fixtureVersion': 2,
      'seed': 20260829,
      'contentHash': hash,
      'works': 500,
      'downloadTasks': 1000,
      'activeDownloads': 3,
      'localRecords': 10000,
      'zipUncompressedBytes': 512 * 1024 * 1024,
      'trackSwitches': 50,
      'worksPath': 'works.json',
      'downloadTasksPath': 'tasks.json',
      'subtitleRootPath': 'subtitles',
      'zipPath': 'nested.zip',
    });

    expect(manifest.contentHash, hash);
    expect(manifest.toReportJson(), isNot(contains('zipPath')));
    expect(manifest.toReportJson()['works'], 500);
  });

  test('rejects legacy or cardinality-incompatible fixtures', () {
    expect(
      () => PerformanceFixtureManifest.fromJson(const {
        'fixtureVersion': 1,
        'seed': 1,
        'contentHash': hash,
        'works': 1,
        'downloadTasks': 1,
        'activeDownloads': 1,
        'localRecords': 1,
        'zipUncompressedBytes': 1,
        'trackSwitches': 1,
        'worksPath': 'works.json',
        'downloadTasksPath': 'tasks.json',
        'subtitleRootPath': 'subtitles',
        'zipPath': 'nested.zip',
      }),
      throwsFormatException,
    );
  });

  test('playback diagnostic JSON contains no source URL field', () {
    final event = PlaybackDiagnosticEvent(
      type: PlaybackDiagnosticEventType.trackLoadFailed,
      timestamp: DateTime.utc(2026, 8, 31),
      trackKey: 'track-hash',
      workId: 123,
      detail: 'StateError',
    );

    expect(event.toJson(), {
      'type': 'trackLoadFailed',
      'timestamp': '2026-08-31T00:00:00.000Z',
      'trackKey': 'track-hash',
      'workId': 123,
      'detail': 'StateError',
    });
    expect(event.toJson().keys, isNot(contains('url')));
  });

  test('playback fixture requires hashed server and content identities', () {
    expect(
      () => PerformancePlaybackFixtureManifest.fromJson({
        'fixtureVersion': 2,
        'serverHash': 'not-a-hash',
        'contentHash': hash,
        'tracks': List.generate(
          10,
          (index) => {'workId': index, 'hash': 'track-$index'},
        ),
      }),
      throwsFormatException,
    );
  });
}
