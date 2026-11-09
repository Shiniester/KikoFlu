import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/app_localizations.dart';
import '../../models/audio_effects_settings.dart';
import '../../providers/audio_effects_provider.dart';
import '../../providers/audio_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/native_audio_effects.dart';
import '../responsive_dialog.dart';

Future<void> showPlaybackAudioEffects(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const PlaybackAudioEffectsDialog(),
);

class PlaybackAudioEffectsDialog extends ConsumerWidget {
  const PlaybackAudioEffectsDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final settings = ref.watch(audioEffectsSettingsProvider);
    final notifier = ref.read(audioEffectsSettingsProvider.notifier);
    final passthrough = ref.watch(audioPassthroughProvider);
    final status = passthrough
        ? AudioEffectsStatus.passthrough
        : ref.watch(audioEffectsStatusProvider).valueOrNull ??
              AudioEffectsStatus.waiting;
    final presets = [
      s.audioEffectsFlat,
      s.audioEffectsBright,
      s.audioEffectsBass,
      s.audioEffectsCrisp,
      s.audioEffectsDull,
      s.audioEffectsVocal,
    ];
    final modes = [
      s.audioEffectsNormal,
      s.audioEffectsSwap,
      s.audioEffectsCloneLeft,
      s.audioEffectsCloneRight,
    ];
    final scenes = [
      s.audioEffectsBathroom,
      s.audioEffectsMuffled,
      s.audioEffectsTelephone,
    ];

    Widget header(String title, VoidCallback reset) => Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        Semantics(
          label: s.audioEffectsResetNamed(title),
          button: true,
          onTap: reset,
          excludeSemantics: true,
          child: TextButton(
            onPressed: reset,
            child: Text(s.audioEffectsResetModule),
          ),
        ),
      ],
    );

    return ResponsiveDialog(
      maxWidth: 760,
      title: Text(s.playbackAudioEffects),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(switch (status) {
              AudioEffectsStatus.waiting => s.audioEffectsWaiting,
              AudioEffectsStatus.ready => s.audioEffectsReady,
              AudioEffectsStatus.passthrough => s.audioEffectsPassthrough,
              AudioEffectsStatus.unavailable => s.audioEffectsUnavailable,
            }),
          ),
          const SizedBox(height: 16),
          header(s.audioEffectsEqualizer, notifier.resetEqualizer),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(s.audioEffectsEqualizer),
            value: settings.equalizerEnabled,
            onChanged: notifier.setEqualizerEnabled,
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final preset in EqualizerPreset.values)
                ChoiceChip(
                  label: Text(presets[preset.index]),
                  selected: settings.preset == preset,
                  onSelected: (_) => notifier.setPreset(preset),
                ),
              if (settings.preset == null)
                Chip(label: Text(s.audioEffectsCustom)),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 560 ? 2 : 1;
              return Wrap(
                spacing: 16,
                children: [
                  for (var i = 0; i < 10; i++)
                    SizedBox(
                      width:
                          (constraints.maxWidth - 16 * (columns - 1)) / columns,
                      child: _EffectSlider(
                        sliderKey: ValueKey('audio-effects-band-$i'),
                        label: AudioEffectsSettings.frequencies[i] < 1000
                            ? '${AudioEffectsSettings.frequencies[i]} Hz'
                            : '${AudioEffectsSettings.frequencies[i] ~/ 1000} kHz',
                        value: settings.gains[i],
                        min: -15,
                        max: 15,
                        divisions: 60,
                        formatted: '${settings.gains[i].toStringAsFixed(1)} dB',
                        onChanged: (value) => notifier.setBand(i, value),
                      ),
                    ),
                ],
              );
            },
          ),
          const Divider(),
          header(s.audioEffectsChannel, notifier.resetChannel),
          DropdownButtonFormField<AudioChannelMode>(
            key: ValueKey(settings.channelMode),
            initialValue: settings.channelMode,
            isExpanded: true,
            decoration: InputDecoration(labelText: s.audioEffectsChannel),
            items: [
              for (final mode in AudioChannelMode.values)
                DropdownMenuItem(value: mode, child: Text(modes[mode.index])),
            ],
            onChanged: (value) {
              if (value != null) notifier.setChannelMode(value);
            },
          ),
          const SizedBox(height: 16),
          const Divider(),
          header(s.audioEffectsBinaural, notifier.resetBinaural),
          DropdownButtonFormField<BinauralMode>(
            key: ValueKey(settings.binauralMode),
            initialValue: settings.binauralMode,
            isExpanded: true,
            decoration: InputDecoration(labelText: s.audioEffectsBinaural),
            items: [
              DropdownMenuItem(
                value: BinauralMode.off,
                child: Text(s.audioEffectsBinauralOff),
              ),
              DropdownMenuItem(
                value: BinauralMode.stereo,
                child: Text(s.audioEffectsBinauralStereo),
              ),
              DropdownMenuItem(
                value: BinauralMode.mono,
                child: Text(s.audioEffectsBinauralMono),
              ),
            ],
            onChanged: (value) {
              if (value != null) notifier.setBinauralMode(value);
            },
          ),
          const SizedBox(height: 12),
          Text(s.audioEffectsStereoHint),
          _EffectSlider(
            sliderKey: const ValueKey('audio-effects-stereo-amount'),
            label: s.audioEffectsStereoIntensity,
            value: settings.stereoAmount,
            min: 0,
            max: 100,
            divisions: 100,
            formatted: '${settings.stereoAmount.round()}%',
            unit: '%',
            onChanged: notifier.setStereoAmount,
          ),
          Text(s.audioEffectsMonoHint),
          _EffectSlider(
            sliderKey: const ValueKey('audio-effects-mono-amount'),
            label: s.audioEffectsMonoIntensity,
            value: settings.monoAmount,
            min: 0,
            max: 100,
            divisions: 100,
            formatted: '${settings.monoAmount.round()}%',
            unit: '%',
            onChanged: notifier.setMonoAmount,
          ),
          const Divider(),
          header(s.audioEffectsScene, notifier.resetScene),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(s.audioEffectsScene),
            value: settings.sceneEnabled,
            onChanged: notifier.setSceneEnabled,
          ),
          DropdownButtonFormField<AudioScene>(
            key: ValueKey(settings.scene),
            initialValue: settings.scene,
            isExpanded: true,
            decoration: InputDecoration(labelText: s.audioEffectsScene),
            items: [
              for (final scene in AudioScene.values)
                DropdownMenuItem(
                  value: scene,
                  child: Text(scenes[scene.index]),
                ),
            ],
            onChanged: (value) {
              if (value != null) notifier.setScene(value);
            },
          ),
          const SizedBox(height: 16),
          _EffectSlider(
            sliderKey: const ValueKey('audio-effects-scene-amount'),
            label: s.audioEffectsIntensity,
            value: settings.sceneAmount,
            min: 0,
            max: 100,
            divisions: 100,
            formatted: '${settings.sceneAmount.round()}%',
            unit: '%',
            onChanged: notifier.setSceneAmount,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: notifier.resetAll,
          child: Text(s.audioEffectsResetAll),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(s.close),
        ),
      ],
    );
  }
}

class _EffectSlider extends StatelessWidget {
  const _EffectSlider({
    required this.sliderKey,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.formatted,
    this.unit = 'dB',
    required this.onChanged,
  });
  final Key sliderKey;
  final String label;
  final double value, min, max;
  final int divisions;
  final String formatted;
  final String unit;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 12,
        children: [Text(label), Text(formatted)],
      ),
      Semantics(
        label: label,
        child: Slider(
          key: sliderKey,
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: formatted,
          onChanged: onChanged,
          semanticFormatterCallback: (value) =>
              '${value.toStringAsFixed(unit == '%' ? 0 : 1)} $unit',
        ),
      ),
    ],
  );
}
