import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/local_subtitle_model_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'kikoflu_local_subtitle_models_test_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('downloads mixed precision models separately and reuses them', () async {
    const expectedFiles = [
      'encoder-epoch-99-avg-1.int8.onnx',
      'decoder-epoch-99-avg-1.onnx',
      'joiner-epoch-99-avg-1.int8.onnx',
      'tokens.txt',
      'silero_vad.onnx',
    ];
    final oldDirectory = Directory(
      p.join(
        temporaryDirectory.path,
        'local_audio_subtitles',
        'ja_reazonspeech',
      ),
    );
    await oldDirectory.create(recursive: true);
    for (final file in expectedFiles) {
      final oldName = file == 'decoder-epoch-99-avg-1.onnx'
          ? 'decoder-epoch-99-avg-1.int8.onnx'
          : file;
      await File(p.join(oldDirectory.path, oldName)).writeAsString('old model');
    }
    final adapter = _DownloadAdapter();
    final store = LocalSubtitleModelStore(
      dio: Dio()..httpClientAdapter = adapter,
      rootDirectory: temporaryDirectory,
    );

    final readyPath = await store.ensureReady(
      cancelToken: CancelToken(),
      onProgress: (_) {},
    );

    expect(
      readyPath,
      p.join(
        temporaryDirectory.path,
        'local_audio_subtitles',
        'ja_reazonspeech_int8_fp32',
      ),
    );
    expect(
      adapter.requests.map((request) => request.uri.pathSegments.last),
      unorderedEquals(expectedFiles),
    );
    expect(
      adapter.requests.map((request) => request.uri.toString()),
      contains(
        'https://huggingface.co/csukuangfj/reazonspeech-k2-v2/resolve/main/decoder-epoch-99-avg-1.onnx',
      ),
    );
    final downloadedFiles = await Directory(readyPath).list().toList();
    expect(
      downloadedFiles.map((file) => p.basename(file.path)),
      unorderedEquals(expectedFiles),
    );

    expect(
      await store.ensureReady(cancelToken: CancelToken(), onProgress: (_) {}),
      readyPath,
    );
    expect(adapter.requests, hasLength(expectedFiles.length));
    expect(await oldDirectory.list().length, expectedFiles.length);
  });

  test('a failed model download is not ready and can be retried', () async {
    final failingAdapter = _DownloadAdapter(failOnRequest: 2);
    final dio = Dio()..httpClientAdapter = failingAdapter;
    final store = LocalSubtitleModelStore(
      dio: dio,
      rootDirectory: temporaryDirectory,
    );

    await expectLater(
      store.ensureReady(cancelToken: CancelToken(), onProgress: (_) {}),
      throwsA(isA<DioException>()),
    );

    final modelDirectory = Directory(
      p.join(
        temporaryDirectory.path,
        'local_audio_subtitles',
        'ja_reazonspeech_int8_fp32',
      ),
    );
    final filesAfterFailure = await modelDirectory
        .list()
        .where((entry) => entry is File)
        .map((entry) => p.basename(entry.path))
        .toList();
    expect(filesAfterFailure, ['encoder-epoch-99-avg-1.int8.onnx']);
    expect(filesAfterFailure.any((name) => name.endsWith('.part')), isFalse);

    final retryAdapter = _DownloadAdapter();
    dio.httpClientAdapter = retryAdapter;
    final progress = <double>[];
    final readyPath = await store.ensureReady(
      cancelToken: CancelToken(),
      onProgress: progress.add,
    );

    expect(readyPath, modelDirectory.path);
    expect(
      (await modelDirectory.list().toList()).whereType<File>(),
      hasLength(5),
    );
    expect(retryAdapter.requests, hasLength(4));
    expect(progress.last, 1);
  });

  test('cancellation between files leaves no temporary download', () async {
    final adapter = _DownloadAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final store = LocalSubtitleModelStore(
      dio: dio,
      rootDirectory: temporaryDirectory,
    );
    final cancelToken = CancelToken();

    await expectLater(
      store.ensureReady(
        cancelToken: cancelToken,
        onProgress: (progress) {
          if (progress >= 0.2 && !cancelToken.isCancelled) {
            cancelToken.cancel('test cancellation');
          }
        },
      ),
      throwsA(isA<DioException>()),
    );

    final modelDirectory = Directory(
      p.join(
        temporaryDirectory.path,
        'local_audio_subtitles',
        'ja_reazonspeech_int8_fp32',
      ),
    );
    final files = await modelDirectory.list().toList();
    expect(files.whereType<File>(), hasLength(1));
    expect(files.any((entry) => entry.path.endsWith('.part')), isFalse);
    expect(adapter.requests, hasLength(1));
  });
}

class _DownloadAdapter implements HttpClientAdapter {
  _DownloadAdapter({this.failOnRequest});

  final int? failOnRequest;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requests.length == failOnRequest) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'offline',
      );
    }
    return ResponseBody.fromString('model data', HttpStatus.ok);
  }

  @override
  void close({bool force = false}) {}
}
