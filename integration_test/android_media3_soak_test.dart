import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kikoeru_flutter/main.dart' as kikoflu_app;
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/playback_diagnostic_event.dart';
import 'package:kikoeru_flutter/src/performance/performance_fixture_manifest.dart';
import 'package:kikoeru_flutter/src/performance/performance_recorder.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/file_tree_utils.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'real account Android Media3 soak and track switching',
    (tester) async {
      const controlPath = String.fromEnvironment(
        'KIKOFLU_PERF_CONTROL_PATH',
        defaultValue:
            '/sdcard/Android/data/com.meteor.kikoeruflutter/files/'
            'performance_fixtures/control.json',
      );
      final control = Map<String, dynamic>.from(
        jsonDecode(await File(controlPath).readAsString()) as Map,
      );
      final label = control['label']! as String;
      final revision = control['revision']! as String;
      final fixtureHash = control['fixtureHash']! as String;
      final playbackManifestPath = control['playbackManifestPath']! as String;
      final soakMinutes = (control['soakMinutes'] as num).toInt();
      final switchCount = (control['trackSwitches'] as num).toInt();
      expect(['baseline', 'candidate'], contains(label));
      expect(revision, matches(RegExp(r'^[a-f0-9]{7,40}$')));
      expect(fixtureHash, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(playbackManifestPath, isNotEmpty);

      final recorder = PerformanceRecorder.instance..start(force: true);
      kikoflu_app.main(const []);
      await _waitForFirstInteractive(tester, recorder);
      await tester.pump(const Duration(seconds: 2));

      final token = StorageService.getString('auth_token')?.trim() ?? '';
      final host = StorageService.getString('server_host')?.trim() ?? '';
      expect(
        token,
        isNotEmpty,
        reason: 'A real account must already be signed in on the device',
      );
      expect(host, isNotEmpty);
      final normalizedHost = _normalizeHost(host);
      final serverHash = sha256.convert(utf8.encode(normalizedHost)).toString();
      final api = KikoeruApiService()..init(token, normalizedHost);

      final playbackManifestFile = File(playbackManifestPath);
      final PerformancePlaybackFixtureManifest playbackManifest;
      if (await playbackManifestFile.exists()) {
        final decoded = jsonDecode(await playbackManifestFile.readAsString());
        playbackManifest = PerformancePlaybackFixtureManifest.fromJson(
          Map<String, Object?>.from(decoded as Map),
        );
        expect(
          playbackManifest.serverHash,
          serverHash,
          reason: 'Playback fixture belongs to a different server',
        );
      } else {
        expect(
          label,
          'baseline',
          reason: 'Only the baseline may select the real playback fixture',
        );
        playbackManifest = await _selectPlaybackFixture(api, serverHash);
        await playbackManifestFile.parent.create(recursive: true);
        await playbackManifestFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(playbackManifest.toJson()),
        );
      }

      final tracks = await _resolvePlaybackTracks(
        api: api,
        manifest: playbackManifest,
        host: normalizedHost,
        token: token,
      );
      expect(tracks, hasLength(playbackManifest.tracks.length));
      expect(tracks.length, greaterThanOrEqualTo(10));

      final service = AudioPlayerService.instance;
      service.debugClearPlaybackDiagnostics();
      await service.setRepeatMode(LoopMode.all);
      await service.updateQueue(tracks);
      await service.play();

      final soakStopwatch = Stopwatch()..start();
      final soakDuration = Duration(minutes: soakMinutes);
      while (soakStopwatch.elapsed < soakDuration) {
        await tester.pump(const Duration(seconds: 1));
      }
      soakStopwatch.stop();

      final switchLatencies = <double>[];
      for (var index = 0; index < switchCount; index++) {
        final nextIndex = (service.currentIndex + 1) % tracks.length;
        final expectedKey = tracks[nextIndex].hash ?? tracks[nextIndex].id;
        final stopwatch = Stopwatch()..start();
        await service.skipToIndex(nextIndex);
        await _waitForPositionAdvance(
          tester,
          service,
          expectedKey: expectedKey,
        );
        stopwatch.stop();
        switchLatencies.add(stopwatch.elapsedMicroseconds / 1000);
      }
      await service.pause();

      final diagnostics = service.debugPlaybackDiagnostics;
      final diagnosticCounts = {
        for (final type in PlaybackDiagnosticEventType.values)
          type.name: diagnostics.where((event) => event.type == type).length,
      };
      final unexpectedBuffering =
          diagnosticCounts[PlaybackDiagnosticEventType
              .unexpectedBuffering
              .name] ??
          0;
      final playbackErrors =
          diagnosticCounts[PlaybackDiagnosticEventType.playbackError.name] ?? 0;
      final cacheErrors =
          diagnosticCounts[PlaybackDiagnosticEventType.cacheError.name] ?? 0;

      binding.reportData = {
        'schemaVersion': 2,
        'label': label,
        'revision': revision,
        'fixtureHash': fixtureHash,
        'playbackFixtureHash': playbackManifest.contentHash,
        'metrics': {
          'playbackDurationMinutes': soakStopwatch.elapsedMilliseconds / 60000,
          'realTrackSwitches': switchLatencies.length,
          'trackSwitchMedianMs': _percentile(switchLatencies, 0.5),
          'trackSwitchP95Ms': _percentile(switchLatencies, 0.95),
          'playbackUnexpectedBufferingCount': unexpectedBuffering,
          'playbackErrorCount': playbackErrors,
          'cacheErrorCount': cacheErrors,
        },
        'diagnosticSummary': {
          'counts': diagnosticCounts,
          'eventCount': diagnostics.length,
        },
        'playbackFixture': playbackManifest.toJson(),
      };
    },
    timeout: const Timeout(Duration(minutes: 45)),
  );
}

Future<PerformancePlaybackFixtureManifest> _selectPlaybackFixture(
  KikoeruApiService api,
  String serverHash,
) async {
  final response = await api.getWorks(
    page: 1,
    pageSize: 80,
    order: 'create_date',
    sort: 'desc',
    seed: 20260829,
  );
  final rawWorks = response['works'];
  if (rawWorks is! List) {
    throw StateError('The server did not return a works list');
  }
  final works =
      rawWorks
          .whereType<Map>()
          .map((work) => Map<String, dynamic>.from(work))
          .where((work) => work['id'] is num)
          .toList(growable: false)
        ..sort(
          (left, right) => (left['id'] as num).toInt().compareTo(
            (right['id'] as num).toInt(),
          ),
        );

  final selected = <PerformancePlaybackTrack>[];
  for (final work in works) {
    final workId = (work['id'] as num).toInt();
    final tree = await api.getWorkTracks(workId, forceRefresh: true);
    for (final item in _flattenAudioFiles(tree)) {
      final hash = FileTreeUtils.property(item, 'hash')?.toString().trim();
      if (hash == null || hash.isEmpty) continue;
      selected.add(PerformancePlaybackTrack(workId: workId, hash: hash));
      if (selected.length >= 10) break;
    }
    if (selected.length >= 10) break;
  }
  if (selected.length < 10) {
    throw StateError('Unable to select at least 10 playable real tracks');
  }
  final canonical = selected
      .map((track) => '${track.workId}:${track.hash}')
      .join('\n');
  return PerformancePlaybackFixtureManifest(
    fixtureVersion: PerformanceFixtureManifest.currentVersion,
    serverHash: serverHash,
    contentHash: sha256
        .convert(utf8.encode('$serverHash\n$canonical'))
        .toString(),
    tracks: List.unmodifiable(selected),
  );
}

Future<List<AudioTrack>> _resolvePlaybackTracks({
  required KikoeruApiService api,
  required PerformancePlaybackFixtureManifest manifest,
  required String host,
  required String token,
}) async {
  final trees = <int, List<dynamic>>{};
  final result = <AudioTrack>[];
  for (final fixture in manifest.tracks) {
    final tree = trees[fixture.workId] ??= await api.getWorkTracks(
      fixture.workId,
      forceRefresh: true,
    );
    dynamic matched;
    for (final item in _flattenAudioFiles(tree)) {
      if (FileTreeUtils.property(item, 'hash')?.toString() == fixture.hash) {
        matched = item;
        break;
      }
    }
    if (matched == null) {
      throw StateError(
        'Playback fixture track is missing: '
        '${fixture.workId}:${fixture.hash}',
      );
    }
    final title = FileTreeUtils.titleOf(matched, defaultValue: fixture.hash);
    final mediaStream = FileTreeUtils.property(
      matched,
      'mediaStreamUrl',
    )?.toString();
    final url = _mediaUrl(
      host: host,
      token: token,
      hash: fixture.hash,
      mediaStreamUrl: mediaStream,
    );
    result.add(
      AudioTrack(
        id: fixture.hash,
        title: title,
        url: url,
        workId: fixture.workId,
        hash: fixture.hash,
      ),
    );
  }
  return result;
}

Iterable<dynamic> _flattenAudioFiles(List<dynamic> items) sync* {
  for (final item in items) {
    if (FileTreeUtils.isFolder(item)) {
      yield* _flattenAudioFiles(FileTreeUtils.childrenOf(item) ?? const []);
    } else if (FileTreeUtils.isAudio(item)) {
      yield item;
    }
  }
}

String _normalizeHost(String host) {
  final normalized = host.startsWith('http://') || host.startsWith('https://')
      ? host
      : 'https://$host';
  return normalized.replaceFirst(RegExp(r'/+$'), '');
}

String _mediaUrl({
  required String host,
  required String token,
  required String hash,
  String? mediaStreamUrl,
}) {
  final raw = mediaStreamUrl == null || mediaStreamUrl.isEmpty
      ? '$host/api/media/stream/$hash'
      : mediaStreamUrl.startsWith('/')
      ? '$host$mediaStreamUrl'
      : mediaStreamUrl;
  final uri = Uri.parse(raw);
  if (uri.queryParameters.containsKey('token')) return uri.toString();
  return uri
      .replace(queryParameters: {...uri.queryParameters, 'token': token})
      .toString();
}

Future<void> _waitForFirstInteractive(
  WidgetTester tester,
  PerformanceRecorder recorder,
) async {
  final timeout = Stopwatch()..start();
  while (recorder.metric('firstInteractiveMs') == null &&
      timeout.elapsed < const Duration(seconds: 90)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(recorder.metric('firstInteractiveMs'), isNotNull);
}

Future<void> _waitForPositionAdvance(
  WidgetTester tester,
  AudioPlayerService service, {
  required String expectedKey,
}) async {
  final timeout = Stopwatch()..start();
  while (timeout.elapsed < const Duration(seconds: 30)) {
    final current = service.currentTrack;
    final key = current?.hash ?? current?.id;
    if (key == expectedKey && service.position > Duration.zero) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  throw TimeoutException('Track did not become ready and advance in 30 s');
}

double _percentile(List<double> values, double percentile) {
  if (values.isEmpty) return 0;
  final sorted = List<double>.of(values)..sort();
  final index = ((sorted.length - 1) * percentile).ceil();
  return sorted[index.clamp(0, sorted.length - 1)];
}
