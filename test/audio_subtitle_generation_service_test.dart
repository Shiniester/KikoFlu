import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/player_subtitle_candidates_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_subtitle_generation_service.dart';
import 'package:kikoeru_flutter/src/services/generated_subtitle_store.dart';
import 'package:kikoeru_flutter/src/services/local_audio_transcriber.dart';
import 'package:kikoeru_flutter/src/services/local_subtitle_model_store.dart';
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _Network extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporaryDirectory;
  final previousOverrides = HttpOverrides.current;

  setUpAll(() => HttpOverrides.global = _Network());
  tearDownAll(() => HttpOverrides.global = previousOverrides);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'audio-subtitle-generation-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'only reuses a parseable subtitle that matches the current audio',
    () async {
      final matchingPath = p.join(temporaryDirectory.path, 'matching.srt');
      final mismatchedPath = p.join(temporaryDirectory.path, 'mismatched.srt');
      final corruptPath = p.join(temporaryDirectory.path, 'corrupt.srt');
      await File(matchingPath).writeAsString(_validSrt);
      await File(mismatchedPath).writeAsString(_validSrt);
      await File(corruptPath).writeAsString('not a subtitle');
      final request = _request(title: 'voice.txt');

      final matchingService = AudioSubtitleGenerationService(
        candidateRepository: _candidateRepository([
          _candidate(matchingPath, matchesCurrentAudio: true),
        ]),
      );
      final mismatchedService = AudioSubtitleGenerationService(
        candidateRepository: _candidateRepository([
          _candidate(mismatchedPath, matchesCurrentAudio: false),
        ]),
      );
      final corruptService = AudioSubtitleGenerationService(
        candidateRepository: _candidateRepository([
          _candidate(corruptPath, matchesCurrentAudio: true),
        ]),
      );

      final matchingResult = await matchingService.generate(
        request,
        CancelToken(),
        (_, _) {},
      );
      final mismatchedResult = await mismatchedService.generate(
        request,
        CancelToken(),
        (_, _) {},
      );
      final corruptResult = await corruptService.generate(
        request,
        CancelToken(),
        (_, _) {},
      );

      expect(matchingResult.status, AudioSubtitleGenerationStatus.skipped);
      expect(
        mismatchedResult.status,
        AudioSubtitleGenerationStatus.unsupported,
      );
      expect(corruptResult.status, AudioSubtitleGenerationStatus.unsupported);
    },
  );

  test(
    'uses the selected online variant even when the original file is local',
    () async {
      final originalPath = p.join(temporaryDirectory.path, '01.wav');
      final selectedLocalPath = p.join(temporaryDirectory.path, '01.mp3');
      await File(originalPath).writeAsBytes([1, 2, 3]);
      await File(selectedLocalPath).writeAsBytes([4, 5, 6]);
      final fileTree = [
        _folder('CD1', [
          _folder('WAV', [
            _audioFile(
              '01.wav',
              hash: 'wav-hash',
              size: 800,
              localPath: originalPath,
            ),
          ]),
          _folder('MP3', [
            _audioFile(
              '01.mp3',
              hash: 'mp3-hash',
              size: 80,
              mediaDownloadUrl: 'https://cdn.example/01.mp3',
              localPath: selectedLocalPath,
            ),
          ]),
        ]),
      ];
      final selectedAudio = const PlayerAudioVariantClassifier()
          .scan(fileTree)
          .singleWhere((variant) => variant.title == '01.mp3');
      final request = _request(
        audioPath: originalPath,
        title: '01.wav',
        hash: 'wav-hash',
        parentPath: 'CD1/WAV',
        fileTree: fileTree,
        downloadUrl: 'https://cdn.example/original.wav',
        selectedAudio: selectedAudio,
      );
      final transcriber = _FakeTranscriber();
      final subtitleStore = _FakeGeneratedSubtitleStore();
      final downloads =
          <
            ({
              String fileName,
              String relativePath,
              String downloadUrl,
              String? hash,
              int? totalBytes,
            })
          >[];
      final service = AudioSubtitleGenerationService(
        modelStore: _FakeModelStore(),
        transcriber: transcriber,
        subtitleStore: subtitleStore,
        candidateRepository: _candidateRepository(const []),
        audioDownloader:
            ({
              required request,
              required fileName,
              required relativePath,
              required downloadUrl,
              required hash,
              required totalBytes,
              required cancelToken,
              required onProgress,
            }) async {
              downloads.add((
                fileName: fileName,
                relativePath: relativePath,
                downloadUrl: downloadUrl,
                hash: hash,
                totalBytes: totalBytes,
              ));
              return '/input/$fileName';
            },
      );

      final result = await service.generate(request, CancelToken(), (_, _) {});

      expect(result.status, AudioSubtitleGenerationStatus.completed);
      expect(downloads, [
        (
          fileName: '01.mp3',
          relativePath: 'CD1/MP3',
          downloadUrl: 'https://cdn.example/01.mp3',
          hash: 'mp3-hash',
          totalBytes: 80,
        ),
      ]);
      expect(transcriber.audioPaths, ['/input/01.mp3']);
      expect(subtitleStore.savedTracks, [same(request.track)]);
    },
  );

  test('uses a selected local file when it has no download URL', () async {
    final originalPath = p.join(temporaryDirectory.path, 'original.wav');
    final selectedPath = p.join(temporaryDirectory.path, 'selected.mp3');
    await File(originalPath).writeAsBytes([1, 2, 3]);
    await File(selectedPath).writeAsBytes([4, 5, 6]);
    final fileTree = [
      _folder('WAV', [
        _audioFile('original.wav', hash: 'original-hash', size: 10),
      ]),
      _folder('MP3', [
        _audioFile(
          'selected.mp3',
          hash: 'local:MP3/selected.mp3',
          size: 3,
          localPath: selectedPath,
        ),
      ]),
    ];
    final selectedAudio = const PlayerAudioVariantClassifier()
        .scan(fileTree)
        .singleWhere((variant) => variant.title == 'selected.mp3');
    final transcriber = _FakeTranscriber();
    var downloadCalls = 0;
    final request = _request(
      audioPath: originalPath,
      title: 'original.wav',
      hash: 'original-hash',
      fileTree: fileTree,
      selectedAudio: selectedAudio,
    );
    final service = AudioSubtitleGenerationService(
      modelStore: _FakeModelStore(),
      transcriber: transcriber,
      subtitleStore: _FakeGeneratedSubtitleStore(),
      candidateRepository: _candidateRepository(const []),
      audioDownloader:
          ({
            required request,
            required fileName,
            required relativePath,
            required downloadUrl,
            required hash,
            required totalBytes,
            required cancelToken,
            required onProgress,
          }) async {
            downloadCalls++;
            return '/unexpected/$fileName';
          },
    );

    final result = await service.generate(request, CancelToken(), (_, _) {});

    expect(result.status, AudioSubtitleGenerationStatus.completed);
    expect(transcriber.audioPaths, [selectedPath]);
    expect(downloadCalls, 0);
  });

  for (final selectedFormat in ['mp3', 'm4a']) {
    test('checks the selected recognition format: $selectedFormat', () async {
      final selectedPath = p.join(
        temporaryDirectory.path,
        'selected.$selectedFormat',
      );
      await File(selectedPath).writeAsBytes([1, 2, 3]);
      final selected = const PlayerAudioVariantClassifier().scan([
        _audioFile(
          'selected.$selectedFormat',
          hash: 'local:selected',
          size: 3,
          localPath: selectedPath,
        ),
      ]).single;
      final transcriber = _FakeTranscriber();
      final service = AudioSubtitleGenerationService(
        modelStore: _FakeModelStore(),
        transcriber: transcriber,
        subtitleStore: _FakeGeneratedSubtitleStore(),
        candidateRepository: _candidateRepository(const []),
      );
      final result = await service.generate(
        _request(
          title: selectedFormat == 'mp3' ? 'original.m4a' : 'original.mp3',
          selectedAudio: selected,
        ),
        CancelToken(),
        (_, _) {},
      );

      expect(
        result.status,
        selectedFormat == 'mp3'
            ? AudioSubtitleGenerationStatus.completed
            : AudioSubtitleGenerationStatus.unsupported,
      );
      expect(
        transcriber.audioPaths,
        selectedFormat == 'mp3' ? [selectedPath] : isEmpty,
      );
    });
  }

  test('cancellation stops the selected audio network download', () async {
    final originalPath = p.join(temporaryDirectory.path, 'original.wav');
    await File(originalPath).writeAsBytes([1, 2, 3]);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final selectedAudio = const PlayerAudioVariantClassifier().scan([
      _audioFile(
        'selected.mp3',
        hash: 'selected-hash',
        size: 100,
        mediaDownloadUrl: 'http://127.0.0.1:${server.port}/selected.mp3',
      ),
    ]).single;
    final downloadStarted = Completer<void>();
    final finishResponse = Completer<void>();
    final responseFinished = Completer<void>();
    server.listen((request) async {
      final response = request.response
        ..bufferOutput = false
        ..statusCode = HttpStatus.ok
        ..contentLength = 6;
      response.add(const [4, 5, 6]);
      await response.flush();
      downloadStarted.complete();
      try {
        await finishResponse.future;
        response.add(const [7, 8, 9]);
        await response.close();
      } catch (_) {
        // The generation cancellation closes the client response.
      } finally {
        responseFinished.complete();
      }
    });
    final cancelToken = CancelToken();
    final transcriber = _FakeTranscriber();
    final service = AudioSubtitleGenerationService(
      modelStore: _FakeModelStore(),
      transcriber: transcriber,
      subtitleStore: _FakeGeneratedSubtitleStore(),
      candidateRepository: _candidateRepository(const []),
    );
    final request = _request(
      audioPath: originalPath,
      title: 'original.wav',
      hash: 'original-hash',
      selectedAudio: selectedAudio,
    );

    final generation = service.generate(request, cancelToken, (_, _) {});
    await downloadStarted.future;
    cancelToken.cancel('test cancellation');
    finishResponse.complete();

    await expectLater(
      generation,
      throwsA(anyOf(isA<DioException>(), isA<HttpException>())),
    );
    await responseFinished.future;
    expect(await File(originalPath).readAsBytes(), [1, 2, 3]);
    expect(transcriber.audioPaths, isEmpty);
  });
  test(
    'preserves ordinary directory and track number prefixes when matching',
    () async {
      final request = _request(
        title: '01(完全版).wav',
        hash: null,
        parentPath: 'CD1/01_本編/WAV',
        fileTree: [
          _folder('CD1', [
            _folder('01_本編', [
              _folder('WAV', [
                _audioFile('01(完全版).wav', hash: 'original-hash', size: 800),
              ]),
              _folder('MP3', [
                _audioFile(
                  '02(SEなし).mp3',
                  hash: 'different-track-hash',
                  size: 70,
                  mediaDownloadUrl: 'https://cdn.example/different-track.mp3',
                ),
              ]),
            ]),
            _folder('02_本編', [
              _folder('MP3', [
                _audioFile(
                  '01(SEなし).mp3',
                  hash: 'other-directory-hash',
                  size: 80,
                  mediaDownloadUrl: 'https://cdn.example/other-directory.mp3',
                ),
              ]),
            ]),
          ]),
        ],
        downloadUrl: 'https://cdn.example/original.wav',
        totalBytes: 800,
      );
      final downloads =
          <({String fileName, String? hash, String downloadUrl})>[];
      final service = AudioSubtitleGenerationService(
        modelStore: _FakeModelStore(),
        transcriber: _FakeTranscriber(),
        subtitleStore: _FakeGeneratedSubtitleStore(),
        candidateRepository: _candidateRepository(const []),
        audioDownloader:
            ({
              required request,
              required fileName,
              required relativePath,
              required downloadUrl,
              required hash,
              required totalBytes,
              required cancelToken,
              required onProgress,
            }) async {
              downloads.add((
                fileName: fileName,
                hash: hash,
                downloadUrl: downloadUrl,
              ));
              return '/input/$fileName';
            },
      );

      final result = await service.generate(request, CancelToken(), (_, _) {});

      expect(result.status, AudioSubtitleGenerationStatus.completed);
      expect(downloads, [
        (
          fileName: '01(完全版).wav',
          hash: 'original-hash',
          downloadUrl: 'https://cdn.example/original.wav',
        ),
      ]);
    },
  );

  test(
    'uses an explicitly selected local MP3 without downloading it',
    () async {
      final alternativePath = p.join(temporaryDirectory.path, '01.mp3');
      await File(alternativePath).writeAsBytes([1, 2, 3]);
      final fileTree = [
        _folder('WAV', [_audioFile('01.wav', hash: 'wav-hash', size: 800)]),
        _folder('MP3', [
          _audioFile(
            '01.mp3',
            hash: 'mp3-hash',
            size: 80,
            localPath: alternativePath,
          ),
        ]),
      ];
      final selectedAudio = const PlayerAudioVariantClassifier()
          .scan(fileTree)
          .singleWhere((variant) => variant.title == '01.mp3');
      final request = _request(
        title: '01.wav',
        hash: null,
        parentPath: 'WAV',
        fileTree: fileTree,
        selectedAudio: selectedAudio,
      );
      final transcriber = _FakeTranscriber();
      var downloadCalls = 0;
      final service = AudioSubtitleGenerationService(
        modelStore: _FakeModelStore(),
        transcriber: transcriber,
        subtitleStore: _FakeGeneratedSubtitleStore(),
        candidateRepository: _candidateRepository(const []),
        audioDownloader:
            ({
              required request,
              required fileName,
              required relativePath,
              required downloadUrl,
              required hash,
              required totalBytes,
              required cancelToken,
              required onProgress,
            }) async {
              downloadCalls++;
              return '/unexpected/$fileName';
            },
      );

      final result = await service.generate(request, CancelToken(), (_, _) {});

      expect(result.status, AudioSubtitleGenerationStatus.completed);
      expect(transcriber.audioPaths, [alternativePath]);
      expect(downloadCalls, 0);
    },
  );

  test(
    'does not save when cancellation reaches the generated subtitle store',
    () async {
      final audioPath = p.join(temporaryDirectory.path, 'voice.mp3');
      await File(audioPath).writeAsBytes([1, 2, 3]);
      final cancelToken = CancelToken();
      final subtitleStore = _FakeGeneratedSubtitleStore();
      final service = AudioSubtitleGenerationService(
        modelStore: _FakeModelStore(),
        transcriber: _FakeTranscriber(
          beforeReturn: (token) => token.cancel('test cancellation'),
        ),
        subtitleStore: subtitleStore,
        candidateRepository: _candidateRepository(const []),
      );

      await expectLater(
        service.generate(
          _request(audioPath: audioPath),
          cancelToken,
          (_, _) {},
        ),
        throwsA(isA<DioException>()),
      );

      expect(subtitleStore.saved, isEmpty);
    },
  );
}

const _validSrt = '1\n00:00:01,000 --> 00:00:02,000\nHello\n';

AudioSubtitleRequest _request({
  String? audioPath,
  String title = 'voice.mp3',
  String? hash = 'voice-hash',
  List<dynamic> fileTree = const [],
  String? parentPath,
  String? downloadUrl,
  int? totalBytes,
  String host = '',
  String token = '',
  PlayerAudioVariant? selectedAudio,
  String? subtitleWorkDirPath,
}) => AudioSubtitleRequest(
  track: AudioTrack(
    id: 'voice',
    title: title,
    url: 'file:///voice.mp3',
    workId: 123,
    hash: hash,
    sourcePath: audioPath,
    subtitleWorkDirPath: subtitleWorkDirPath,
  ),
  fileTree: fileTree,
  parentPath: parentPath,
  downloadUrl: downloadUrl,
  totalBytes: totalBytes,
  selectedAudio: selectedAudio,
  host: host,
  token: token,
);

Map<String, dynamic> _folder(String title, List<dynamic> children) => {
  'type': 'folder',
  'title': title,
  'children': children,
};

Map<String, dynamic> _audioFile(
  String title, {
  required String hash,
  required int size,
  String? mediaDownloadUrl,
  String? localPath,
}) => {
  'type': 'audio',
  'title': title,
  'hash': hash,
  'size': size,
  if (mediaDownloadUrl != null) 'mediaDownloadUrl': mediaDownloadUrl,
  if (localPath != null) 'localPath': localPath,
};

PlayerSubtitleCandidateRepository _candidateRepository(
  List<PlayerSubtitleCandidate> candidates,
) => PlayerSubtitleCandidateRepository(libraryLoader: (_) async => candidates);

PlayerSubtitleCandidate _candidate(
  String localPath, {
  required bool matchesCurrentAudio,
}) => PlayerSubtitleCandidate(
  identity: 'local:$localPath',
  title: p.basename(localPath),
  pathLabel: localPath,
  origin: PlayerSubtitleCandidateOrigin.library,
  source: {'localPath': localPath},
  matchesCurrentAudio: matchesCurrentAudio,
  matchScore: matchesCurrentAudio ? 1 : 0,
  sameDirectory: false,
);

class _FakeModelStore extends LocalSubtitleModelStore {
  int calls = 0;

  @override
  Future<String> ensureReady({
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    calls++;
    return '/models';
  }
}

class _FakeTranscriber extends LocalAudioTranscriber {
  _FakeTranscriber({this.beforeReturn});

  final void Function(CancelToken cancelToken)? beforeReturn;
  final audioPaths = <String>[];
  final modelDirectories = <String>[];

  @override
  Future<String> transcribe({
    required String audioPath,
    required String modelDirectory,
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    audioPaths.add(audioPath);
    modelDirectories.add(modelDirectory);
    beforeReturn?.call(cancelToken);
    return _validSrt;
  }
}

class _FakeGeneratedSubtitleStore extends GeneratedSubtitleStore {
  final saved = <String>[];
  final savedTracks = <AudioTrack>[];

  @override
  Future<String> save(
    AudioTrack track,
    String srt, {
    required CancelToken cancelToken,
  }) async {
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    saved.add(srt);
    savedTracks.add(track);
    return '/generated/${track.title.replaceAll('.mp3', '.srt')}';
  }
}
