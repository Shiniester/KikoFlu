import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_effects_settings.dart';
import 'package:kikoeru_flutter/src/services/native_audio_effects.dart';

void main() {
  test('runtime updates send only targets present in the active graph', () {
    final dry = AudioEffectsSettings();
    final channel = dry.copyWith(channelMode: AudioChannelMode.swap);
    expect(AudioEffectsGraph.controls(channel, previous: dry), [
      ['af-command', 'kiko_channel', 'volume', '1', 'volume@channel_mode'],
    ]);
    final saved = dry.copyWith(gains: [0, 0, 0, 0, 0, -5, 0, 0, 0, 0]);
    expect(AudioEffectsGraph.controls(saved, previous: dry), isEmpty);
    final cut = saved.copyWith(equalizerEnabled: true);
    final enable = AudioEffectsGraph.controls(cut, previous: dry);
    expect(enable.length, 2);
    expect(enable.first[1], 'kiko_eq');
    expect(enable.last[2], 'enable');
    final changed = cut.copyWith(gains: [0, 0, 0, 0, 0, -10, 0, 0, 0, 0]);
    expect(AudioEffectsGraph.controls(changed, previous: cut).length, 1);
    final disable = AudioEffectsGraph.controls(dry, previous: cut);
    expect(disable, isEmpty);

    final muffled = dry.copyWith(
      sceneEnabled: true,
      scene: AudioScene.muffled,
      sceneAmount: 75,
    );
    final bathroom = muffled.copyWith(scene: AudioScene.bathroom);
    expect(AudioEffectsGraph.controls(bathroom, previous: muffled), [
      ['af-command', 'kiko_scene', 'volume', '0.75', 'volume@scene_amount'],
    ]);
  });
  test(
    'filter preflight accepts git builds and rejects old or missing filters',
    () {
      const filters =
          'aeval,aformat,alimiter,asendcmd,equalizer,biquad,volume,asetpts';
      expect(
        AudioEffectsGraph.supportsFilterGraph(filters, 'N-128607-g1ddef7d76'),
        true,
      );
      expect(AudioEffectsGraph.supportsFilterGraph(filters, 'n6.0'), true);
      expect(AudioEffectsGraph.supportsFilterGraph(filters, '4.2.7'), false);
      expect(AudioEffectsGraph.supportsFilterGraph(null, '6.0'), false);
      expect(
        AudioEffectsGraph.supportsFilterGraph('lavfi,format', 'n6.0'),
        false,
      );
    },
  );
  test(
    'exports exact production graphs for actual native PCM contracts',
    () async {
      final snapshots = <String, AudioEffectsSettings>{
        'dry': AudioEffectsSettings(),
        'neutral': AudioEffectsSettings(
          equalizerEnabled: true,
          sceneEnabled: true,
          sceneAmount: 0,
        ),
        for (final mode in AudioChannelMode.values)
          'channel_${mode.index}': AudioEffectsSettings(channelMode: mode),
        for (final scene in AudioScene.values)
          for (final amount in [0.0, 50.0, 100.0])
            'scene_${scene.index}_${amount.round()}': AudioEffectsSettings(
              sceneEnabled: true,
              scene: scene,
              sceneAmount: amount,
            ),
        for (final mode in [BinauralMode.stereo, BinauralMode.mono])
          for (final amount in [0.0, 50.0, 100.0])
            'binaural_${mode.name}_${amount.round()}': AudioEffectsSettings(
              binauralMode: mode,
              stereoAmount: amount,
              monoAmount: amount,
            ),
        'eq_cut': AudioEffectsSettings(
          equalizerEnabled: true,
          gains: const [0, 0, 0, 0, 0, -15, 0, 0, 0, 0],
        ),
        'eq_boost': AudioEffectsSettings(
          equalizerEnabled: true,
          gains: const [0, 0, 0, 0, 0, 15, 0, 0, 0, 0],
        ),
      };
      final directory = await Directory(
        'build/audio-effects-contract',
      ).create(recursive: true);
      await File('${directory.path}/graphs.json').writeAsString(
        jsonEncode({
          for (final system in [false, true])
            system ? 'systemLibrary' : 'customLibrary': {
              for (final entry in snapshots.entries)
                entry.key: AudioEffectsGraph.render(
                  entry.value,
                  systemLibrary: system,
                ),
              for (final mode in [BinauralMode.stereo, BinauralMode.mono])
                for (final amount in [0.0, 50.0, 100.0])
                  'linear_${mode.name}_${amount.round()}':
                      '${AudioEffectsGraph.binaural(AudioEffectsSettings(binauralMode: mode, stereoAmount: amount, monoAmount: amount)).replaceAll('[out]', '[before_guard]')};[before_guard]pan=stereo|c0=c0|c1=c1[out]',
              'binauralControls': {
                'stereo': AudioEffectsGraph.controls(
                  AudioEffectsSettings(
                    binauralMode: BinauralMode.stereo,
                    stereoAmount: 100,
                  ),
                  previous: AudioEffectsSettings(),
                ),
                'mono': AudioEffectsGraph.controls(
                  AudioEffectsSettings(
                    binauralMode: BinauralMode.mono,
                    monoAmount: 100,
                  ),
                  previous: AudioEffectsSettings(
                    binauralMode: BinauralMode.stereo,
                    stereoAmount: 100,
                  ),
                ),
              },
              'controls': AudioEffectsGraph.controls(
                AudioEffectsSettings(channelMode: AudioChannelMode.cloneLeft),
                previous: AudioEffectsSettings(
                  channelMode: AudioChannelMode.swap,
                ),
              ),
            },
        }),
      );
    },
  );
  test(
    'source snapshots render every module with bounded exact named controls',
    () {
      for (final system in [false, true]) {
        for (final mode in AudioChannelMode.values) {
          final settings = AudioEffectsSettings(
            equalizerEnabled: true,
            gains: AudioEffectsSettings.curves[EqualizerPreset.vocal],
            channelMode: mode == AudioChannelMode.normal
                ? AudioChannelMode.swap
                : mode,
            binauralMode: BinauralMode.stereo,
            stereoAmount: 100,
            sceneEnabled: true,
            scene: AudioScene.muffled,
            sceneAmount: 75,
          );
          final graph = AudioEffectsGraph.render(
            settings,
            systemLibrary: system,
          );
          expect(graph.contains('__'), false);
          expect(
            graph.indexOf('@kiko_eq'),
            lessThan(graph.indexOf('@kiko_channel')),
          );
          expect(
            graph.indexOf('@kiko_channel'),
            lessThan(graph.indexOf('@kiko_binaural')),
          );
          expect(
            graph.indexOf('@kiko_binaural'),
            lessThan(graph.indexOf('@kiko_guard')),
          );
          expect(
            graph.indexOf('@kiko_guard'),
            lessThan(graph.indexOf('@kiko_scene')),
          );
          expect(
            graph.indexOf('@kiko_scene'),
            lessThan(
              graph.indexOf(
                '@kiko_${AudioEffectsGraph.sceneNames[settings.scene.index]}',
              ),
            ),
          );
          expect(graph, contains('t=o:w=1:g=6.5'));
          expect(graph, contains('volume@scene_amount=2.75'));
          final controls = AudioEffectsGraph.controls(settings);
          expect(
            controls.every(
              (command) =>
                  command.length == 5 &&
                  command[0] == 'af-command' &&
                  command[1].startsWith('kiko_') &&
                  command[4].contains('@'),
            ),
            true,
          );
          expect(
            controls.any(
              (command) =>
                  command.contains('loadfile') || command.contains('seek'),
            ),
            false,
          );
        }
      }
    },
  );
  test('active modules install only the graphs required for their outputs', () {
    expect(
      AudioEffectsGraph.render(AudioEffectsSettings(), systemLibrary: false),
      '',
    );
    expect(
      AudioEffectsGraph.render(AudioEffectsSettings(), systemLibrary: true),
      '',
    );
    final scene = AudioEffectsSettings(
      sceneEnabled: true,
      scene: AudioScene.telephone,
      sceneAmount: 50,
    );
    final graph = AudioEffectsGraph.render(scene, systemLibrary: false);
    expect(graph, contains('@kiko_scene'));
    expect(graph, contains('@kiko_telephone'));
    expect(graph, isNot(contains('@kiko_eq')));
    expect(graph, isNot(contains('@kiko_channel')));
    expect(graph, isNot(contains('@kiko_binaural')));
    expect(graph, isNot(contains('@kiko_bathroom')));
    expect(graph, isNot(contains('@kiko_through_wall')));
    expect(AudioEffectsGraph.activeModules(scene), ['scene', 'telephone']);
    expect(
      AudioEffectsGraph.controls(
        scene,
      ).every((command) => command[1] == 'kiko_scene'),
      true,
    );

    final equalizer = AudioEffectsSettings(
      equalizerEnabled: true,
      gains: const [0, 0, 0, 0, 0, 9, 0, 0, 0, 0],
    );
    expect(
      AudioEffectsGraph.render(equalizer, systemLibrary: false),
      contains('@kiko_eq'),
    );
    expect(AudioEffectsGraph.activeModules(equalizer), ['eq', 'guard']);
    expect(
      AudioEffectsGraph.controls(
        equalizer,
      ).every((command) => command[1] == 'kiko_eq'),
      true,
    );
  });
  test('binaural delta targets stop old mode before starting the new mode', () {
    final stereo = AudioEffectsSettings(
      binauralMode: BinauralMode.stereo,
      stereoAmount: 100,
    );
    final mono = AudioEffectsSettings(
      binauralMode: BinauralMode.mono,
      monoAmount: 75,
    );
    final controls = AudioEffectsGraph.controls(mono, previous: stereo);
    expect(controls, [
      ['af-command', 'kiko_binaural', 'volume', '0', 'volume@stereo_amount'],
      ['af-command', 'kiko_binaural', 'volume', '0.75', 'volume@mono_amount'],
    ]);
    expect(
      AudioEffectsGraph.controls(
        mono.copyWith(stereoAmount: 20),
        previous: mono,
      ),
      isEmpty,
    );
    expect(
      AudioEffectsGraph.controls(AudioEffectsSettings(), previous: mono),
      isEmpty,
    );
  });
}
