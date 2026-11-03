import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/mpv_audio_decoder.dart';
import 'package:path/path.dart' as p;

void main() {
  test('PCM conversion rejects incomplete float samples', () {
    final bytes = Uint8List(8);
    final values = ByteData.sublistView(bytes)
      ..setFloat32(0, 0.5, Endian.host)
      ..setFloat32(4, -0.25, Endian.host);

    expect(MpvAudioDecoder.samplesForTesting(bytes), [0.5, -0.25]);
    expect(
      () => MpvAudioDecoder.samplesForTesting(values.buffer.asUint8List(0, 7)),
      throwsStateError,
    );
  });

  final libmpv = Platform.environment['LIBMPV_LIBRARY_PATH'];
  final skipLibmpv = libmpv == null || libmpv.isEmpty
      ? 'Set LIBMPV_LIBRARY_PATH to test the packaged libmpv.'
      : null;
  final fixtures = p.join(
    'third_party',
    'local_audio_decoder',
    'test',
    'fixtures',
  );
  final expectedFrames = <String, int>{
    'test-aac.aac': 32694,
    'test-aac.m4a': 32322,
    'test-vorbis.ogg': 32000,
    'test-opus.ogg': 32000,
    'test-opus.opus': 32000,
  };

  for (final fixture in expectedFrames.entries) {
    test('decodes ${fixture.key} in bounded reads', () async {
      final decoder = MpvAudioDecoder.open(p.join(fixtures, fixture.key));
      try {
        var frames = 0;
        var peak = 0.0;
        while (true) {
          final samples = await decoder.read(511);
          if (samples.isEmpty) break;
          expect(samples.length, lessThanOrEqualTo(511));
          for (final sample in samples) {
            expect(sample.isFinite, isTrue);
            if (sample.abs() > peak) peak = sample.abs();
          }
          frames += samples.length;
        }
        // Decoder padding can vary between libmpv builds.
        expect(
          frames,
          inInclusiveRange(fixture.value - 1600, fixture.value + 1600),
        );
        expect(peak, greaterThan(0));
      } finally {
        await decoder.close();
      }
    }, skip: skipLibmpv);
  }

  test(
    'reads a short file even if the writer finishes before the reader',
    () async {
      final decoder = MpvAudioDecoder.open(p.join(fixtures, '日本語音声.wav'));
      try {
        final first = await decoder.read(16000);
        expect(first, hasLength(4000));
        expect(await decoder.read(16000), isEmpty);
      } finally {
        await decoder.close();
      }
    },
    skip: skipLibmpv,
  );

  test('decodes chained Vorbis with an audio format change', () async {
    final decoder = MpvAudioDecoder.open(
      p.join(fixtures, 'test-chained-vorbis.ogg'),
    );
    try {
      var frames = 0;
      while (true) {
        final samples = await decoder
            .read(4096)
            .timeout(const Duration(seconds: 10));
        if (samples.isEmpty) break;
        expect(samples.every((sample) => sample.isFinite), isTrue);
        frames += samples.length;
      }
      expect(frames, inInclusiveRange(63000, 65000));
    } finally {
      await decoder.close().timeout(const Duration(seconds: 10));
    }
  }, skip: skipLibmpv);

  test('decodes AAC from a Unicode cache path with an audio suffix', () async {
    final directory = await Directory.systemTemp.createTemp('音声-');
    try {
      final cached = p.join(directory.path, '日本語.audio');
      await File(p.join(fixtures, 'test-aac.aac')).copy(cached);
      final decoder = MpvAudioDecoder.open(cached);
      try {
        var frames = 0;
        while (true) {
          final samples = await decoder.read(4096);
          if (samples.isEmpty) break;
          frames += samples.length;
        }
        final expected = expectedFrames['test-aac.aac']!;
        expect(frames, inInclusiveRange(expected - 1600, expected + 1600));
      } finally {
        await decoder.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: skipLibmpv);

  for (final input in ['not-audio.m4a', 'missing.m4a']) {
    test(
      'reports failed input $input without waiting for a pipe writer',
      () async {
        final decoder = MpvAudioDecoder.open(p.join(fixtures, input));
        try {
          await expectLater(
            decoder.read(1024).timeout(const Duration(seconds: 10)),
            throwsStateError,
          );
        } finally {
          await decoder.close().timeout(const Duration(seconds: 10));
        }
      },
      skip: skipLibmpv,
    );
  }

  test('closes immediately before starting the first read', () async {
    for (var index = 0; index < 3; index++) {
      final decoder = MpvAudioDecoder.open(p.join(fixtures, 'test-opus.opus'));
      await decoder.close().timeout(const Duration(seconds: 10));
      await expectLater(decoder.read(1), throwsStateError);
    }
  }, skip: skipLibmpv);

  test(
    'cancellation drains and closes a decoder with unread output',
    () async {
      final decoder = MpvAudioDecoder.open(p.join(fixtures, 'test-opus.opus'));
      expect(await decoder.read(1), hasLength(1));
      var checks = 0;
      await expectLater(
        decoder.read(
          160000,
          checkCancelled: () {
            if (++checks == 2) throw StateError('cancelled');
          },
        ),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'cancelled'),
        ),
      );
      await decoder.close().timeout(const Duration(seconds: 10));
      await decoder.close();
      await expectLater(decoder.read(1), throwsStateError);
    },
    skip: skipLibmpv,
  );

  test(
    'cancellation closes a full Windows PCM pipe',
    () async {
      final decoder = MpvAudioDecoder.open(p.join(fixtures, 'test-opus.opus'));
      try {
        final wait = Stopwatch()..start();
        while (decoder.bufferedBytesForTesting < 65536 &&
            wait.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(decoder.bufferedBytesForTesting, greaterThanOrEqualTo(65536));
        await expectLater(
          decoder.read(1, checkCancelled: () => throw StateError('cancelled')),
          throwsStateError,
        );
      } finally {
        await decoder.close().timeout(const Duration(seconds: 10));
      }
    },
    skip: !Platform.isWindows ? 'Windows named pipe test.' : skipLibmpv,
  );
}
