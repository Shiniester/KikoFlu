import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Downloads and reuses the fixed Japanese local transcription model files.
class LocalSubtitleModelStore {
  static const _downloads = <String, String>{
    'encoder-epoch-99-avg-1.int8.onnx':
        'https://huggingface.co/csukuangfj/reazonspeech-k2-v2/resolve/main/encoder-epoch-99-avg-1.int8.onnx',
    'decoder-epoch-99-avg-1.onnx':
        'https://huggingface.co/csukuangfj/reazonspeech-k2-v2/resolve/main/decoder-epoch-99-avg-1.onnx',
    'joiner-epoch-99-avg-1.int8.onnx':
        'https://huggingface.co/csukuangfj/reazonspeech-k2-v2/resolve/main/joiner-epoch-99-avg-1.int8.onnx',
    'tokens.txt':
        'https://huggingface.co/csukuangfj/reazonspeech-k2-v2/resolve/main/tokens.txt',
    'silero_vad.onnx':
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
  };

  final Dio _dio;
  final Directory? rootDirectory;

  LocalSubtitleModelStore({Dio? dio, this.rootDirectory}) : _dio = dio ?? Dio();

  /// Returns the directory once every required model file is ready.
  Future<String> ensureReady({
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    _throwIfCancelled(cancelToken);
    final root = rootDirectory ?? await getApplicationSupportDirectory();
    final modelDirectory = Directory(
      p.join(root.path, 'local_audio_subtitles', 'ja_reazonspeech_int8_fp32'),
    );
    await modelDirectory.create(recursive: true);

    final entries = _downloads.entries.toList(growable: false);
    var completed = 0;
    for (final entry in entries) {
      _throwIfCancelled(cancelToken);
      final target = File(p.join(modelDirectory.path, entry.key));
      if (await target.exists() && await target.length() > 0) {
        completed++;
        onProgress(completed / entries.length);
        continue;
      }
      if (await target.exists()) await target.delete();

      final temporary = File('${target.path}.part');
      if (await temporary.exists()) await temporary.delete();
      try {
        await _dio.download(
          entry.value,
          temporary.path,
          cancelToken: cancelToken,
          options: Options(receiveTimeout: const Duration(minutes: 2)),
          onReceiveProgress: (received, total) {
            if (total > 0) {
              final fraction = (received / total).clamp(0.0, 1.0).toDouble();
              onProgress((completed + fraction) / entries.length);
            }
          },
        );
        _throwIfCancelled(cancelToken);
        if (await temporary.length() == 0) {
          throw FileSystemException(
            'Downloaded model file is empty',
            temporary.path,
          );
        }
        await temporary.rename(target.path);
        completed++;
        onProgress(completed / entries.length);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }

    _throwIfCancelled(cancelToken);
    onProgress(1);
    return modelDirectory.path;
  }

  static void _throwIfCancelled(CancelToken cancelToken) {
    final error = cancelToken.cancelError;
    if (error != null) throw error;
  }
}
