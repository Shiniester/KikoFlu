import 'package:ffi/ffi.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
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
    'real system-library controller applies paused latest state and preserves source identity',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
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
        // PCM file output has no hardware clock; pace test input before production DSP.
        native.onLoadHooks.add(() async {
          final chain = await native.getProperty('af');
          const clock = 'asetnsamples=n=128:p=0,arealtime';
          await native.setProperty(
            'af',
            '@test_clock:lavfi=o=[threads=1]:graph=%${clock.length}%$clock,$chain',
          );
        });
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
        await player.stop();
        expect(statuses, contains(AudioEffectsStatus.ready));
        expect(statuses, isNot(contains(AudioEffectsStatus.unavailable)));
        final actual = audioEffectsPcm(await output.readAsBytes());
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
        await player.stream.position
            .firstWhere(
              (position) => position >= const Duration(milliseconds: 100),
            )
            .timeout(const Duration(seconds: 10));
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
        await controller.configure(native, AudioEffectsSettings(), false);
        native.onLoadHooks.add(() async {
          loads++;
          final chain = await native.getProperty('af');
          const clock = 'asetnsamples=n=128:p=0,arealtime';
          await native.setProperty(
            'af',
            '@test_clock:lavfi=o=[threads=1]:graph=%${clock.length}%$clock,$chain',
          );
        });
        final started = player.stream.position.firstWhere(
          (position) => position >= const Duration(milliseconds: 500),
        );
        await player.open(Media(source.path));
        await started.timeout(const Duration(seconds: 10));
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

        final offStart = await output.length();
        await controller.configure(native, AudioEffectsSettings(), false);
        await waitForOutput(false, offStart);
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
        await player.stop();
        final actual = audioEffectsPcm(await output.readAsBytes());
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
              .map((row) => (row.$1 / 32768, row.$2 / 32768))
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
          final rates = <int>[];
          final params = player.stream.audioParams.listen((value) {
            final rate = value.sampleRate;
            if (rate != null && (rates.isEmpty || rates.last != rate)) {
              rates.add(rate);
            }
          });
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
              !hot && binaural ? target : AudioEffectsSettings(),
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
            final started = player.stream.position.firstWhere(
              (position) => position >= const Duration(milliseconds: 300),
            );
            final completed = player.stream.completed.firstWhere(
              (done) => done,
            );
            await player.open(Media(manifest.path));
            await started.timeout(const Duration(seconds: 10));
            if (hot) {
              final graph = await native.getProperty('af');
              expect(
                await native.getProperty('audio-params/samplerate'),
                '44100',
              );
              await controller.configure(native, target, false);
              expect(await native.getProperty('af'), graph);
              expect(
                await native.getProperty('audio-params/samplerate'),
                '44100',
              );
            }
            await completed.timeout(const Duration(seconds: 30));
            expect(rates.first, 44100);
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
            await player.stop();
            return audioEffectsPcm(await output.readAsBytes());
          } finally {
            await params.cancel();
            await controller.dispose();
            await player.dispose();
          }
        }

        try {
          final dry = await capture(false);
          final hot = await capture(true);
          expect(hot.length, dry.length);
          expect(dry.length, greaterThan(2000));
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
          await player.stop();
          final actual = audioEffectsPcm(await output.readAsBytes());
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
