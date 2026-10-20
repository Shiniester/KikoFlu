import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:local_audio_decoder/local_audio_decoder.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

const int _sampleRate = 16000;
const int _readFrames = _sampleRate * 10;
const int _vadWindowSize = 512;
const int _vadWindowsBetweenYields = 32;
const double _maximumSpeechSeconds = 12;
const double _vadBufferSeconds = 24;

typedef _SubtitleCue = ({int startSample, int endSample, String text});

final class _VadWindowBuffer {
  final _pending = <double>[];

  Iterable<Float32List> add(Float32List samples) sync* {
    var offset = 0;
    if (_pending.isNotEmpty) {
      final needed = _vadWindowSize - _pending.length;
      final remaining = samples.length - offset;
      final count = remaining < needed ? remaining : needed;
      _pending.addAll(samples.getRange(offset, offset + count));
      offset += count;
      if (_pending.length == _vadWindowSize) {
        yield Float32List.fromList(_pending);
        _pending.clear();
      }
    }

    while (offset + _vadWindowSize <= samples.length) {
      yield samples.sublist(offset, offset + _vadWindowSize);
      offset += _vadWindowSize;
    }
    if (offset < samples.length) {
      _pending.addAll(samples.getRange(offset, samples.length));
    }
  }

  Iterable<Float32List> flush() sync* {
    if (_pending.isEmpty) return;

    final window = Float32List(_vadWindowSize);
    window.setRange(0, _pending.length, _pending);
    _pending.clear();
    yield window;
  }
}

/// Transcribes supported local audio into a complete original-language SRT.
class LocalAudioTranscriber {
  /// Splits decoder-sized reads into the fixed Silero window size.
  @visibleForTesting
  static List<Float32List> vadWindowsForTesting(List<Float32List> reads) {
    final buffer = _VadWindowBuffer();
    return [
      for (final read in reads) ...buffer.add(read),
      ...buffer.flush(),
    ];
  }

  /// Formats sample-offset cues using the production SRT formatter.
  @visibleForTesting
  static String formatSrtForTesting(
    List<({int startSample, int endSample, String text})> cues,
  ) => _formatSrt(cues);

  Future<String> transcribe({
    required String audioPath,
    required String modelDirectory,
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    _throwIfRequestCancelled(cancelToken);

    final messages = ReceivePort();
    final completer = Completer<String>();
    SendPort? workerControlPort;
    var cancellationRequested = false;
    var finished = false;

    messages.listen((message) {
      if (message == null) {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('Local transcription worker exited without a result.'),
          );
        }
        return;
      }

      if (message is List && message.length >= 2) {
        final error = message[0]?.toString() ?? 'Unknown worker error';
        final stack = message[1]?.toString() ?? '';
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('Local transcription worker failed: $error'),
            StackTrace.fromString(stack),
          );
        }
        return;
      }

      if (message is! Map) return;
      switch (message['type']) {
        case 'ready':
          final port = message['port'];
          if (port is SendPort) {
            workerControlPort = port;
            if (cancellationRequested) port.send(null);
          }
          break;
        case 'progress':
          final progress = message['value'];
          if (progress is num) {
            onProgress(progress.toDouble().clamp(0.0, 1.0).toDouble());
          }
          break;
        case 'result':
          if (!completer.isCompleted) {
            completer.complete(message['srt'] as String);
          }
          break;
        case 'cancelled':
          if (!completer.isCompleted) {
            try {
              _throwIfRequestCancelled(cancelToken);
              completer.completeError(
                StateError('Local transcription was cancelled.'),
              );
            } catch (error, stack) {
              completer.completeError(error, stack);
            }
          }
          break;
        case 'error':
          if (!completer.isCompleted) {
            completer.completeError(
              StateError('Local transcription failed: ${message['message']}'),
              StackTrace.fromString(message['stack']?.toString() ?? ''),
            );
          }
          break;
      }
    });

    unawaited(
      cancelToken.whenCancel.then((_) {
        cancellationRequested = true;
        if (!finished) workerControlPort?.send(null);
      }),
    );

    Isolate? worker;
    try {
      worker = await Isolate.spawn<List<Object?>>(
        _startTranscriptionWorker,
        <Object?>[audioPath, modelDirectory, messages.sendPort],
        onError: messages.sendPort,
        onExit: messages.sendPort,
        errorsAreFatal: true,
      );
      final result = await completer.future;
      _throwIfRequestCancelled(cancelToken);
      return result;
    } finally {
      finished = true;
      worker?.kill(priority: Isolate.immediate);
      messages.close();
    }
  }

  static String _formatSrt(List<_SubtitleCue> cues) {
    final sorted = cues.where((cue) => cue.text.trim().isNotEmpty).toList()
      ..sort((a, b) => a.startSample.compareTo(b.startSample));
    if (sorted.isEmpty) return '';

    final output = StringBuffer();
    for (var index = 0; index < sorted.length; index++) {
      final cue = sorted[index];
      final startSample = cue.startSample < 0 ? 0 : cue.startSample;
      final endSample = cue.endSample < startSample
          ? startSample
          : cue.endSample;
      final startMilliseconds = (startSample * 1000 / _sampleRate).round();
      final endMilliseconds = (endSample * 1000 / _sampleRate).round();
      output
        ..writeln(index + 1)
        ..writeln(
          '${_formatTime(startMilliseconds)} --> ${_formatTime(endMilliseconds <= startMilliseconds ? startMilliseconds + 1 : endMilliseconds)}',
        )
        ..writeln(cue.text.trim().replaceAll(RegExp(r'[\r\n]+'), ' '));
      if (index + 1 < sorted.length) output.writeln();
    }
    return output.toString();
  }

  static String _formatTime(int milliseconds) {
    final hours = milliseconds ~/ 3600000;
    final minutes = (milliseconds ~/ 60000) % 60;
    final seconds = (milliseconds ~/ 1000) % 60;
    final fraction = milliseconds % 1000;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')},${fraction.toString().padLeft(3, '0')}';
  }
}

void _throwIfRequestCancelled(CancelToken cancelToken) {
  final error = cancelToken.cancelError;
  if (error != null) throw error;
}

void _startTranscriptionWorker(List<Object?> arguments) {
  unawaited(
    _transcribeInWorker(
      arguments[0] as String,
      arguments[1] as String,
      arguments[2] as SendPort,
    ),
  );
}

Future<void> _transcribeInWorker(
  String audioPath,
  String modelDirectory,
  SendPort parentPort,
) async {
  final controlPort = ReceivePort();
  var cancellationRequested = false;
  controlPort.listen((_) => cancellationRequested = true);

  LocalAudioDecoder? decoder;
  sherpa.OfflineRecognizer? recognizer;
  sherpa.VoiceActivityDetector? vad;
  late Map<String, Object?> outcome;
  final cues = <_SubtitleCue>[];

  try {
    parentPort.send({'type': 'ready', 'port': controlPort.sendPort});
    await Future<void>.delayed(Duration.zero);
    _throwIfCancelled(() => cancellationRequested);

    final audioDecoder = LocalAudioDecoder.open(
      audioPath,
      sampleRate: _sampleRate,
    );
    decoder = audioDecoder;
    sherpa.initBindings();
    String modelPath(String fileName) => p.join(modelDirectory, fileName);
    final offlineRecognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          transducer: sherpa.OfflineTransducerModelConfig(
            encoder: modelPath('encoder-epoch-99-avg-1.int8.onnx'),
            decoder: modelPath('decoder-epoch-99-avg-1.int8.onnx'),
            joiner: modelPath('joiner-epoch-99-avg-1.int8.onnx'),
          ),
          tokens: modelPath('tokens.txt'),
          numThreads: 2,
          debug: false,
        ),
      ),
    );
    recognizer = offlineRecognizer;
    final detector = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: modelPath('silero_vad.onnx'),
          windowSize: _vadWindowSize,
          maxSpeechDuration: _maximumSpeechSeconds,
        ),
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: _vadBufferSeconds,
    );
    vad = detector;

    _sendProgress(parentPort, 0);
    final vadWindowBuffer = _VadWindowBuffer();
    var processedVadWindows = 0;
    var processedFrames = 0;
    while (true) {
      await Future<void>.delayed(Duration.zero);
      _throwIfCancelled(() => cancellationRequested);
      final samples = audioDecoder.read(_readFrames);
      if (samples.isEmpty) break;

      for (final window in vadWindowBuffer.add(samples)) {
        detector.acceptWaveform(window);
        processedVadWindows++;
        if (processedVadWindows % _vadWindowsBetweenYields == 0) {
          await Future<void>.delayed(Duration.zero);
          _throwIfCancelled(() => cancellationRequested);
        }
      }
      processedFrames += samples.length;
      await _drainSpeechSegments(
        vad: detector,
        recognizer: offlineRecognizer,
        cues: cues,
        parentPort: parentPort,
        isCancelled: () => cancellationRequested,
        audioEndSample: audioDecoder.totalFrames,
      );
      _sendProgress(
        parentPort,
        audioDecoder.totalFrames > 0
            ? 0.9 * processedFrames / audioDecoder.totalFrames
            : 0,
      );
    }

    _throwIfCancelled(() => cancellationRequested);
    for (final window in vadWindowBuffer.flush()) {
      detector.acceptWaveform(window);
    }
    detector.flush();
    await _drainSpeechSegments(
      vad: detector,
      recognizer: offlineRecognizer,
      cues: cues,
      parentPort: parentPort,
      isCancelled: () => cancellationRequested,
      audioEndSample: audioDecoder.totalFrames,
    );
    await Future<void>.delayed(Duration.zero);
    _throwIfCancelled(() => cancellationRequested);

    final srt = LocalAudioTranscriber._formatSrt(cues);
    if (srt.isEmpty) throw StateError('No speech was recognized in the audio.');
    outcome = {'type': 'result', 'srt': srt};
  } on _TranscriptionCancelled {
    outcome = {'type': 'cancelled'};
  } catch (error, stack) {
    outcome = cancellationRequested
        ? {'type': 'cancelled'}
        : {
            'type': 'error',
            'message': error.toString(),
            'stack': stack.toString(),
          };
  } finally {
    try {
      decoder?.close();
    } finally {
      try {
        vad?.free();
      } finally {
        try {
          recognizer?.free();
        } finally {
          controlPort.close();
        }
      }
    }
  }

  parentPort.send(outcome);
}

Future<void> _drainSpeechSegments({
  required sherpa.VoiceActivityDetector vad,
  required sherpa.OfflineRecognizer recognizer,
  required List<_SubtitleCue> cues,
  required SendPort parentPort,
  required bool Function() isCancelled,
  required int audioEndSample,
}) async {
  while (!vad.isEmpty()) {
    _throwIfCancelled(isCancelled);
    final segment = vad.front();
    vad.pop();
    if (segment.samples.isEmpty) continue;

    final stream = recognizer.createStream();
    late String text;
    try {
      stream.acceptWaveform(samples: segment.samples, sampleRate: _sampleRate);
      recognizer.decode(stream);
      text = recognizer.getResult(stream).text.trim();
    } finally {
      stream.free();
    }

    if (text.isNotEmpty) {
      final startSample = segment.start < 0 ? 0 : segment.start;
      cues.add((
        startSample: startSample,
        endSample: (startSample + segment.samples.length).clamp(
          0,
          audioEndSample,
        ).toInt(),
        text: text,
      ));
    }
    await Future<void>.delayed(Duration.zero);
    _throwIfCancelled(isCancelled);
  }
}

void _sendProgress(SendPort port, double progress) {
  port.send({'type': 'progress', 'value': progress.clamp(0.0, 1.0)});
}

void _throwIfCancelled(bool Function() isCancelled) {
  if (isCancelled()) throw const _TranscriptionCancelled();
}

final class _TranscriptionCancelled implements Exception {
  const _TranscriptionCancelled();
}
