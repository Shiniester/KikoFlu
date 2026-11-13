import 'package:ffi/ffi.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kikoeru_flutter/src/models/audio_effects_settings.dart';
import 'package:kikoeru_flutter/src/services/native_audio_effects.dart';
import '../integration_test/audio_effects_native_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['KIKOFLU_AUDIO_LIBMPV'];
  setUpAll(() {
    if (library != null) MediaKit.ensureInitialized(libmpv: library);
  });

  test(
    'real native controller applies paused latest state and preserves source identity',
    () async {
      final ready = Completer<void>();
      final player = Player(
        configuration: PlayerConfiguration(ready: ready.complete),
      );
      final native = player.platform as NativePlayer;
      await ready.future.timeout(const Duration(seconds: 10));
      final statuses = <AudioEffectsStatus>[];
      final controller = NativeAudioEffects(statuses.add);
      final directory = await Directory.systemTemp.createTemp(
        'kiko-effects-host-',
      );
      final source = File('${directory.path}/source.wav');
      final output = File('${directory.path}/capture.pcm');
      final frames = List.generate(
        240017,
        (n) => (1000 + n % 997, -3000 - n % 991),
      );
      await source.writeAsBytes(audioEffectsWav(frames, 48000));
      try {
        for (final entry in {
          'ao': 'pcm',
          'ao-pcm-waveheader': 'no',
          'ao-pcm-file': output.path,
          'audio-format': 'float',
          'audio-samplerate': '48000',
          'audio-channels': 'stereo',
        }.entries) {
          await native.setProperty(entry.key, entry.value);
        }
        await controller.configure(native, AudioEffectsSettings(), false);
        await player.open(Media(source.path), play: false);
        await player.seek(Duration.zero);
        final path = await native.getProperty('path');
        final position = await native.getProperty('time-pos');
        for (final mode in [
          AudioChannelMode.swap,
          AudioChannelMode.cloneLeft,
          AudioChannelMode.cloneRight,
        ]) {
          await controller.configure(
            native,
            AudioEffectsSettings(channelMode: mode),
            false,
          );
        }
        expect(await native.getProperty('path'), path);
        expect(await native.getProperty('time-pos'), position);
        expect(player.state.playlist.medias.length, 1);
        final completed = player.stream.completed.firstWhere((done) => done);
        await player.play();
        await completed.timeout(const Duration(seconds: 15));
        final actual = await _finishPcmCapture(native, output);
        expect(statuses, contains(AudioEffectsStatus.ready));
        expect(statuses, isNot(contains(AudioEffectsStatus.unavailable)));
        expect(actual.length, frames.length);
        // Control changes slew over 20 ms. The final channel mapping must persist.
        for (var n = 4096; n < frames.length; n++) {
          expect(actual[n].$1, frames[n].$2 / 32768);
          expect(actual[n].$2, frames[n].$2 / 32768);
        }
      } finally {
        await controller.dispose();
        await player.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: library == null
        ? 'Set KIKOFLU_AUDIO_LIBMPV to run real headless native output.'
        : false,
  );

  test(
    'a reverted effect setting takes effect before the first sample',
    () async {
      final frames = List.generate(4817, (n) => (1000 + n, -3000 - n));
      final left = AudioEffectsSettings(
        channelMode: AudioChannelMode.cloneLeft,
      );
      final capture = await _captureInitialEffects(
        audioEffectsWav(frames, 48000),
        left,
        onLoad: (controller, native) async {
          await controller.configure(
            native,
            left.copyWith(channelMode: AudioChannelMode.cloneRight),
            false,
          );
          await controller.configure(native, left, false);
        },
      );
      expect(
        audioEffectsPcm(capture),
        frames.map((row) => (row.$1 / 32768, row.$1 / 32768)),
      );
    },
    skip: library == null,
  );

  test(
    'seek history reset keeps the resident graph when live controls did not change',
    () async {
      final frames = List.generate(48000, (n) => (1000 + n, -3000 - n));
      final graphs = <String>[];
      await _captureInitialEffects(
        audioEffectsWav(frames, 48000),
        AudioEffectsSettings(channelMode: AudioChannelMode.cloneLeft),
        onLoad: (_, native) async {
          const clock = 'asetnsamples=n=128:p=0,arealtime';
          final chain = await native.getProperty('af');
          _setNativeAf(
            native,
            '@test_clock:lavfi=o=[threads=1]:graph=%${clock.length}%$clock,$chain',
          );
          graphs.add(await native.getProperty('af'));
        },
        duringPlayback: (controller, native) async {
          controller.resetHistory();
          expect(await native.getProperty('af'), graphs.single);
        },
      );
    },
    skip: library == null,
  );

  test(
    'seek clears scene reverb history when the graph is current',
    () async {
      final ready = Completer<void>();
      final player = Player(
        configuration: PlayerConfiguration(ready: ready.complete),
      );
      await ready.future.timeout(const Duration(seconds: 10));
      final native = player.platform as NativePlayer;
      final statuses = <AudioEffectsStatus>[];
      final controller = NativeAudioEffects(statuses.add);
      final directory = await Directory.systemTemp.createTemp(
        'kiko-effects-scene-seek-',
      );
      final source = File('${directory.path}/source.wav');
      final output = File('${directory.path}/capture.pcm');
      const rate = 48000;
      const silenceStart = rate * 19 ~/ 5;
      final frames = List.generate(rate * 4, (n) {
        if (n >= silenceStart) return (0, 0);
        final sample = (12000 * math.sin(2 * math.pi * 1000 * n / rate)).round();
        return (sample, sample);
      });
      await source.writeAsBytes(audioEffectsWav(frames, rate));
      try {
        for (final entry in {
          'ao': 'pcm',
          'ao-pcm-waveheader': 'no',
          'ao-pcm-append': 'yes',
          'ao-pcm-file': output.path,
          'audio-format': 'float',
          'audio-samplerate': '$rate',
          'audio-channels': 'stereo',
        }.entries) {
          await native.setProperty(entry.key, entry.value);
        }
        await controller.configure(
          native,
          AudioEffectsSettings(
            sceneEnabled: true,
            scene: AudioScene.bathroom,
            sceneAmount: 100,
          ),
          false,
        );
        native.onLoadHooks.add(() async {
          final chain = await native.getProperty('af');
          const clock = 'asetnsamples=n=128:p=0,arealtime';
          await native.setProperty(
            'af',
            '@test_clock:lavfi=o=[threads=1]:graph=%${clock.length}%$clock,$chain',
          );
        });
        final completed = player.stream.completed.firstWhere((done) => done);
        await player.open(Media(source.path));
        await _waitForNativePosition(native, .3);
        controller.resetHistory();
        await player.seek(
          const Duration(milliseconds: silenceStart * 1000 ~/ rate),
        );
        await completed.timeout(const Duration(seconds: 15));
        final actual = await _finishPcmCapture(native, output);
        expect(actual.length, greaterThan(rate * 19 ~/ 5));
        for (var n = actual.length - rate ~/ 5; n < actual.length; n++) {
          expect(actual[n].$1.abs(), lessThan(1e-6));
          expect(actual[n].$2.abs(), lessThan(1e-6));
        }
        expect(statuses, isNot(contains(AudioEffectsStatus.unavailable)));
      } finally {
        await controller.dispose();
        await player.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: library == null,
  );

  test('neutral effects preserve all six channels of 5.1 PCM', () async {
    const frameCount = 4817;
    const channels = 6;
    const samples = [0, 0, 0, 7000, 1000, -2000];
    const wavHeaderBytes = 68;
    final wav = Uint8List(wavHeaderBytes + frameCount * channels * 2);
    final data = ByteData.sublistView(wav);
    wav.setRange(0, 4, 'RIFF'.codeUnits);
    wav.setRange(8, 16, 'WAVEfmt '.codeUnits);
    wav.setRange(60, 64, 'data'.codeUnits);
    data
      ..setUint32(4, wav.length - 8, Endian.little)
      ..setUint32(16, 40, Endian.little)
      ..setUint16(20, 0xfffe, Endian.little) // WAVEFORMATEXTENSIBLE
      ..setUint16(22, channels, Endian.little)
      ..setUint32(24, 48000, Endian.little)
      ..setUint32(28, 48000 * channels * 2, Endian.little)
      ..setUint16(32, channels * 2, Endian.little)
      ..setUint16(34, 16, Endian.little)
      ..setUint16(36, 22, Endian.little)
      ..setUint16(38, 16, Endian.little)
      ..setUint32(40, 0x3f, Endian.little) // FL, FR, FC, LFE, BL, BR
      ..setUint32(64, wav.length - wavHeaderBytes, Endian.little);
    // PCM subformat GUID.
    wav.setRange(44, 60, [
      1,
      0,
      0,
      0,
      0,
      0,
      16,
      0,
      128,
      0,
      0,
      170,
      0,
      56,
      155,
      113,
    ]);
    for (var i = 0; i < frameCount * channels; i++) {
      data.setInt16(
        wavHeaderBytes + 2 * i,
        samples[i % channels],
        Endian.little,
      );
    }
    final capture = ByteData.sublistView(
      await _captureInitialEffects(
        wav,
        AudioEffectsSettings(sceneEnabled: true, sceneAmount: 0),
        channels: '5.1',
      ),
    );
    expect(capture.lengthInBytes, frameCount * channels * 4);
    for (var i = 0; i < frameCount * channels; i++) {
      expect(
        capture.getFloat32(4 * i, Endian.little),
        samples[i % channels] / 32768,
      );
    }
  }, skip: library == null);

  test(
    'live scene switching installs only the selected scene and keeps neutral output',
    () async {
      const rate = 48000;
      final frames = List.generate(
        rate * 4 + 17,
        (n) => (1000 + n * 7 % 19001, -3000 - n * 11 % 17003),
      );
      final muffled = AudioEffectsSettings(
        sceneEnabled: true,
        scene: AudioScene.muffled,
        sceneAmount: 100,
      );
      final capture = await _captureInitialEffects(
        audioEffectsWav(frames, rate),
        muffled,
        onLoad: (_, native) async {
          final graph = await native.getProperty('af');
          const clock = 'asetnsamples=n=128:p=0,arealtime';
          _setNativeAf(
            native,
            '@test_clock:lavfi=o=[threads=1]:graph=%${clock.length}%$clock,$graph',
          );
        },
        duringPlayback: (controller, native) async {
          await _waitForNativePosition(native, .3);
          await controller.configure(
            native,
            muffled.copyWith(scene: AudioScene.bathroom),
            false,
          );
          final switched = await native.getProperty('af');
          expect(switched, contains('@kiko_bathroom'));
          expect(switched, isNot(contains('@kiko_through_wall')));
          expect(switched, isNot(contains('@kiko_telephone')));
          const clock = 'asetnsamples=n=128:p=0,arealtime';
          _setNativeAf(
            native,
            '@test_clock:lavfi=o=[threads=1]:graph=%${clock.length}%$clock,$switched',
          );
        },
      );
      final actual = audioEffectsPcm(capture);
      expect(actual, hasLength(frames.length));
      bool dry(int i) =>
          actual[i] == (frames[i].$1 / 32768, frames[i].$2 / 32768);
      expect(dry(rate ~/ 4), false);
      expect(dry(frames.length - rate ~/ 4), false);
    },
    skip: library == null,
  );

  test(
    'composed source snapshots preserve prepared tails and clear scene history',
    () async {
      final ready = Completer<void>();
      final player = Player(
        configuration: PlayerConfiguration(ready: ready.complete),
      );
      await ready.future.timeout(const Duration(seconds: 10));
      final native = player.platform as NativePlayer;
      final statuses = <AudioEffectsStatus>[];
      final controller = NativeAudioEffects(statuses.add);
      final directory = await Directory.systemTemp.createTemp(
        'kiko-effects-boundary-',
      );
      final a = File('${directory.path}/a.wav');
      final b = File('${directory.path}/b.wav');
      final output = File('${directory.path}/capture.pcm');
      final frames = List.generate(
        288017,
        (n) => n < 287000 ? (10000 + n % 997, -6000 - n % 991) : (0, 0),
      );
      final silence = List.generate(24017, (_) => (0, 0));
      await a.writeAsBytes(audioEffectsWav(frames, 48000));
      await b.writeAsBytes(audioEffectsWav(silence, 48000));
      var loads = 0;
      try {
        for (final entry in {
          'ao': 'pcm',
          'ao-pcm-waveheader': 'no',
          'ao-pcm-append': 'yes',
          'ao-pcm-file': output.path,
          'audio-format': 'float',
          'audio-samplerate': '48000',
          'audio-channels': 'stereo',
          'prefetch-playlist': 'yes',
          'keep-open': 'no',
        }.entries) {
          await native.setProperty(entry.key, entry.value);
        }
        await controller.configure(
          native,
          AudioEffectsSettings(
            sceneEnabled: true,
            sceneAmount: 100,
            binauralMode: BinauralMode.mono,
            monoAmount: 50,
          ),
          false,
        );
        native.onLoadHooks.add(() async {
          loads++;
          final chain = await native.getProperty('af');
          const clock = 'asetnsamples=n=128:p=0,arealtime';
          await native.setProperty(
            'af',
            '@test_clock:lavfi=o=[threads=1]:graph=%${clock.length}%$clock,$chain',
          );
        });
        final bStarted = player.stream.playlist.firstWhere(
          (playlist) => playlist.index == 1,
        );
        await player.open(Playlist([Media(a.path), Media(b.path)]));
        await _waitForNativePosition(native, .1);
        expect(await native.getProperty('playlist-playing-pos'), '0');
        await controller.configure(
          native,
          AudioEffectsSettings(
            sceneEnabled: true,
            sceneAmount: 100,
            binauralMode: BinauralMode.mono,
            monoAmount: 100,
          ),
          false,
        );
        await bStarted.timeout(const Duration(seconds: 15));
        await player.stream.completed
            .firstWhere((done) => done)
            .timeout(const Duration(seconds: 15));
        final drainDeadline = DateTime.now().add(const Duration(seconds: 10));
        while (await native.getProperty('idle-active') != 'yes') {
          if (DateTime.now().isAfter(drainDeadline)) {
            throw TimeoutException('Prepared output did not drain');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await player.stop();
        final actual = audioEffectsPcm(await output.readAsBytes());
        expect(loads, 2);
        expect(actual.length, frames.length + silence.length);
        expect(
          actual.skip(frames.length).every((row) => row.$1 == 0 && row.$2 == 0),
          true,
        );
        expect(
          actual.take(frames.length).any((row) => row.$1 != 0 || row.$2 != 0),
          true,
        );
        expect(statuses, isNot(contains(AudioEffectsStatus.unavailable)));
      } finally {
        await controller.dispose();
        await player.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: library == null
        ? 'Set KIKOFLU_AUDIO_LIBMPV to run real headless native output.'
        : false,
  );

  test(
    'live controls retain latest target after seek resets the resident graph',
    () async {
      final ready = Completer<void>();
      final player = Player(
        configuration: PlayerConfiguration(ready: ready.complete),
      );
      await ready.future.timeout(const Duration(seconds: 10));
      final native = player.platform as NativePlayer;
      final statuses = <AudioEffectsStatus>[];
      final controller = NativeAudioEffects(statuses.add);
      final directory = await Directory.systemTemp.createTemp(
        'kiko-effects-seek-',
      );
      final source = File('${directory.path}/source.wav');
      final output = File('${directory.path}/capture.pcm');
      final frames = List.generate(
        480017,
        (n) => (1000 + (n * 7) % 19001, -3000 - (n * 11) % 17003),
      );
      await source.writeAsBytes(audioEffectsWav(frames, 48000));
      var loads = 0;
      try {
        for (final entry in {
          'ao': 'pcm',
          'ao-pcm-waveheader': 'no',
          'ao-pcm-append': 'yes',
          'ao-pcm-file': output.path,
          'audio-format': 'float',
          'audio-samplerate': '48000',
          'audio-channels': 'stereo',
        }.entries) {
          await native.setProperty(entry.key, entry.value);
        }
        final swap = AudioEffectsSettings(channelMode: AudioChannelMode.swap);
        await controller.configure(native, swap, false);
        native.onLoadHooks.add(() async {
          loads++;
          final chain = await native.getProperty('af');
          const clock = 'asetnsamples=n=128:p=0,arealtime';
          await native.setProperty(
            'af',
            '@test_clock:lavfi=o=[threads=1]:graph=%${clock.length}%$clock,$chain',
          );
        });
        await player.open(Media(source.path));
        await _waitForNativePosition(native, .5);
        final graph = await native.getProperty('af');
        Future<void> waitForOutput(bool duplicated, int previousLength) async {
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (DateTime.now().isBefore(deadline)) {
            if (await output.length() > previousLength) {
              final emitted = audioEffectsPcm(await output.readAsBytes());
              if ((emitted.last.$1 == emitted.last.$2) == duplicated) return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          throw TimeoutException('Hot controls did not reach expected PCM');
        }

        final path = await native.getProperty('path');
        final position = double.parse(await native.getProperty('time-pos'));
        final onStart = await output.length();
        await controller.configure(
          native,
          AudioEffectsSettings(channelMode: AudioChannelMode.cloneRight),
          false,
        );
        expect(await native.getProperty('af'), graph);
        await waitForOutput(true, onStart);

        final swapStart = await output.length();
        await controller.configure(native, swap, false);
        await waitForOutput(false, swapStart);
        final reenableStart = await output.length();
        await controller.configure(
          native,
          AudioEffectsSettings(channelMode: AudioChannelMode.cloneRight),
          false,
        );
        await waitForOutput(true, reenableStart);
        expect(await native.getProperty('path'), path);
        expect(
          double.parse(await native.getProperty('time-pos')),
          greaterThan(position),
        );
        expect(loads, 1);
        expect(await native.getProperty('eof-reached'), 'no');
        controller.resetHistory();
        final resetGraph = AudioEffectsGraph.render(
          AudioEffectsSettings(channelMode: AudioChannelMode.cloneRight),
          systemLibrary: false,
        );
        const clock = 'asetnsamples=n=128:p=0,arealtime';
        _setNativeAf(
          native,
          '@test_clock:lavfi=o=[threads=1]:graph=%${clock.length}%$clock,$resetGraph',
        );
        final complete = player.stream.completed.firstWhere((done) => done);
        await player.seek(const Duration(seconds: 2));
        await complete.timeout(const Duration(seconds: 15));
        expect(
          await native.getProperty('af'),
          contains('volume@channel_mode=3'),
        );
        expect(loads, 1);
        final actual = await _finishPcmCapture(native, output);
        await Directory('build/audio-effects-contract').create(recursive: true);
        await output.copy(
          'build/audio-effects-contract/native-seek-output.pcm',
        );
        final expectedTail = frames.skip(2 * 48000).toList();
        expect(actual.length, greaterThan(expectedTail.length + 128));
        expect(
          actual.take(128).toList(),
          frames
              .take(128)
              .map((row) => (row.$2 / 32768, row.$1 / 32768))
              .toList(),
        );
        expect(
          actual.skip(actual.length - expectedTail.length).toList(),
          expectedTail.map((row) => (row.$2 / 32768, row.$2 / 32768)).toList(),
        );
        expect(statuses, isNot(contains(AudioEffectsStatus.unavailable)));
      } finally {
        await controller.dispose();
        await player.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: library == null
        ? 'Set KIKOFLU_AUDIO_LIBMPV to run real headless native output.'
        : false,
  );
  for (final binaural in [false, true]) {
    test(
      'latest ${binaural ? 'binaural' : 'channel'} live target survives HLS Fs changes with fixed output sample rate',
      () async {
        final target = AudioEffectsSettings(
          channelMode: AudioChannelMode.cloneRight,
          binauralMode: binaural ? BinauralMode.mono : BinauralMode.off,
          monoAmount: 100,
        );
        final directory = await Directory.systemTemp.createTemp(
          'kiko-effects-fs-',
        );
        final fixture = Directory('tool/audio_effects/fixtures/hls-fs-change');
        for (final name in ['0.aac', '1.aac']) {
          await File('${fixture.path}/$name').copy('${directory.path}/$name');
        }
        final manifest = File('${directory.path}/switch.m3u8');
        await manifest.writeAsString(
          '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n${List.filled(12, '#EXTINF:0.5,\n0.aac\n').join()}#EXT-X-DISCONTINUITY\n#EXTINF:0.5,\n1.aac\n#EXT-X-DISCONTINUITY\n#EXTINF:0.5,\n0.aac\n#EXT-X-DISCONTINUITY\n#EXTINF:0.5,\n1.aac\n#EXT-X-ENDLIST\n',
        );
        Future<List<(double, double)>> capture(bool hot) async {
          final ready = Completer<void>();
          final player = Player(
            configuration: PlayerConfiguration(ready: ready.complete),
          );
          await ready.future.timeout(const Duration(seconds: 10));
          final native = player.platform as NativePlayer;
          final statuses = <AudioEffectsStatus>[];
          final controller = NativeAudioEffects(statuses.add);
          final output = File('${directory.path}/${hot ? 'hot' : 'dry'}.pcm');
          var loads = 0;
          try {
            for (final entry in {
              'ao': 'pcm',
              'ao-pcm-waveheader': 'no',
              'ao-pcm-append': 'yes',
              'ao-pcm-file': output.path,
              'audio-format': 'float',
              'audio-samplerate': '48000',
              'audio-channels': 'stereo',
              'cache-on-disk': 'no',
            }.entries) {
              await native.setProperty(entry.key, entry.value);
            }
            await controller.configure(
              native,
              hot
                  ? AudioEffectsSettings(channelMode: AudioChannelMode.swap)
                  : binaural
                  ? target
                  : AudioEffectsSettings(),
              false,
            );
            native.onLoadHooks.add(() async {
              loads++;
              final chain = await native.getProperty('af');
              const clock = 'asetnsamples=n=128:p=0,arealtime';
              await native.setProperty(
                'af',
                [
                  '@test_clock:lavfi=o=[threads=1]:graph=%${clock.length}%$clock',
                  if (chain.isNotEmpty) chain,
                ].join(','),
              );
            });
            final completed = player.stream.completed.firstWhere(
              (done) => done,
            );
            await player.open(Media(manifest.path));
            await _waitForNativePosition(native, .3);
            expect(
              await native.getProperty('audio-params/samplerate'),
              '44100',
            );
            if (hot) {
              final graph = await native.getProperty('af');
              await controller.configure(native, target, false);
              if (binaural) {
                final switched = await native.getProperty('af');
                expect(switched, contains('volume@channel_mode=3'));
                expect(switched, contains('volume@mono_amount=1.0'));
                const clock = 'asetnsamples=n=128:p=0,arealtime';
                _setNativeAf(
                  native,
                  '@test_clock:lavfi=o=[threads=1]:graph=%${clock.length}%$clock,$switched',
                );
              } else {
                expect(await native.getProperty('af'), graph);
              }
              expect(
                await native.getProperty('audio-params/samplerate'),
                '44100',
              );
            }
            await completed.timeout(const Duration(seconds: 30));
            expect(
              await native.getProperty('audio-params/samplerate'),
              '96000',
            );
            expect(
              await native.getProperty('audio-out-params/samplerate'),
              '48000',
            );
            expect(loads, 1);
            expect(statuses, isNot(contains(AudioEffectsStatus.unavailable)));
            return await _finishPcmCapture(native, output);
          } finally {
            await controller.dispose();
            await player.dispose();
          }
        }

        try {
          final dry = await capture(false);
          final hot = await capture(true);
          expect(dry.length, 382405);
          expect(hot.length, dry.length);
          expect(dry.take(128).any((row) => row.$1 != row.$2), true);
          for (var n = hot.length - 2000; n < hot.length; n++) {
            expect(hot[n].$1, closeTo(binaural ? dry[n].$1 : dry[n].$2, 1e-6));
            expect(hot[n].$2, closeTo(dry[n].$2, 1e-6));
          }
        } finally {
          await directory.delete(recursive: true);
        }
      },
      skip: library == null
          ? 'Set KIKOFLU_AUDIO_LIBMPV to run real headless native output.'
          : false,
    );
  }

  test(
    'passthrough bypasses native DSP and exiting restores retained modules',
    () async {
      final ready = Completer<void>();
      final player = Player(
        configuration: PlayerConfiguration(ready: ready.complete),
      );
      await ready.future.timeout(const Duration(seconds: 10));
      final native = player.platform as NativePlayer;
      final statuses = <AudioEffectsStatus>[];
      final controller = NativeAudioEffects(statuses.add);
      final directory = await Directory.systemTemp.createTemp(
        'kiko-effects-passthrough-',
      );
      final source = File('${directory.path}/source.wav');
      final frames = List.generate(
        24017,
        (n) => (1000 + n % 997, -3000 - n % 991),
      );
      await source.writeAsBytes(audioEffectsWav(frames, 48000));
      final settings = AudioEffectsSettings(
        equalizerEnabled: true,
        gains: AudioEffectsSettings.curves[EqualizerPreset.vocal],
        channelMode: AudioChannelMode.cloneRight,
        sceneEnabled: true,
        scene: AudioScene.telephone,
        sceneAmount: 100,
      );
      try {
        for (final bypass in [true, false]) {
          final output = File('${directory.path}/$bypass.pcm');
          for (final entry in {
            'ao': 'pcm',
            'ao-pcm-waveheader': 'no',
            'ao-pcm-file': output.path,
            'audio-format': 'float',
            'audio-samplerate': '48000',
            'audio-channels': 'stereo',
            'cache-on-disk': 'no',
          }.entries) {
            await native.setProperty(entry.key, entry.value);
          }
          await controller.configure(native, settings, bypass);
          if (bypass) expect(await native.getProperty('af'), '');
          final completed = player.stream.completed.firstWhere((done) => done);
          await player.open(Media(source.path));
          await completed.timeout(const Duration(seconds: 10));
          final actual = await _finishPcmCapture(native, output);
          expect(actual.length, frames.length);
          if (bypass) {
            expect(
              actual,
              frames.map((row) => (row.$1 / 32768, row.$2 / 32768)).toList(),
            );
            expect(statuses, contains(AudioEffectsStatus.passthrough));
          } else {
            expect(
              actual.every((row) => row.$1 == row.$2 && row.$1.isFinite),
              true,
            );
            expect(actual.last.$1, isNot(frames.last.$1 / 32768));
            expect(statuses.last, AudioEffectsStatus.ready);
          }
        }
      } finally {
        await controller.dispose();
        await player.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: library == null
        ? 'Set KIKOFLU_AUDIO_LIBMPV to run real headless native output.'
        : false,
  );
}

Future<Uint8List> _captureInitialEffects(
  Uint8List wav,
  AudioEffectsSettings settings, {
  String channels = 'stereo',
  Future<void> Function(NativeAudioEffects, NativePlayer)? onLoad,
  Future<void> Function(NativeAudioEffects, NativePlayer)? duringPlayback,
}) async {
  final ready = Completer<void>();
  final player = Player(
    configuration: PlayerConfiguration(ready: ready.complete),
  );
  final native = player.platform as NativePlayer;
  final controller = NativeAudioEffects((_) {});
  final directory = await Directory.systemTemp.createTemp('kiko-effects-load-');
  try {
    await ready.future.timeout(const Duration(seconds: 10));
    final input = File('${directory.path}/input.wav');
    final output = File('${directory.path}/output.pcm');
    await input.writeAsBytes(wav);
    for (final entry in {
      'ao': 'pcm',
      'ao-pcm-waveheader': 'no',
      'ao-pcm-file': output.path,
      'audio-format': 'float',
      'audio-samplerate': '48000',
      'audio-channels': channels,
      'demuxer-lavf-format': 'wav',
      'gapless-audio': 'no',
    }.entries) {
      await native.setProperty(entry.key, entry.value);
    }
    await controller.configure(native, settings, false);
    if (onLoad != null) {
      native.onLoadHooks.add(() => onLoad(controller, native));
    }
    final completed = player.stream.completed.firstWhere((value) => value);
    await player.open(Media(input.path));
    if (duringPlayback != null) await duringPlayback(controller, native);
    await completed.timeout(const Duration(seconds: 10));
    return await _finishPcmCaptureBytes(native, output);
  } finally {
    await controller.dispose();
    await player.dispose();
    await directory.delete(recursive: true);
  }
}

Future<void> _waitForNativePosition(NativePlayer player, double seconds) async {
  // The arealtime test filter can delay libmpv position notifications.
  final elapsed = Stopwatch()..start();
  while (true) {
    final position = double.tryParse(await player.getProperty('time-pos'));
    if (position != null && position >= seconds) return;
    if (elapsed.elapsed >= const Duration(seconds: 10)) {
      throw TimeoutException('Native playback did not reach $seconds seconds');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<List<(double, double)>> _finishPcmCapture(
  NativePlayer player,
  File output,
) async => audioEffectsPcm(await _finishPcmCaptureBytes(player, output));

Future<Uint8List> _finishPcmCaptureBytes(
  NativePlayer player,
  File output,
) async {
  await player.stop();
  // The stop reply can arrive before mpv closes the buffered PCM file.
  await player.setProperty('ao', 'null');
  expect(await player.getProperty('current-ao'), isNot('pcm'));
  return output.readAsBytes();
}

void _setNativeAf(NativePlayer player, String graph) {
  final name = 'af'.toNativeUtf8();
  final value = graph.toNativeUtf8();
  try {
    expect(
      player.mpv.mpv_set_property_string(player.ctx, name.cast(), value.cast()),
      0,
    );
  } finally {
    calloc.free(name);
    calloc.free(value);
  }
}
