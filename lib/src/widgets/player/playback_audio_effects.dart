import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/app_localizations.dart';
import '../../models/audio_effects_settings.dart';
import '../../providers/audio_effects_provider.dart';
import '../../providers/audio_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/native_audio_effects.dart';
import '../responsive_dialog.dart';

Future<void> showPlaybackAudioEffects(BuildContext context) =>
    showResponsiveBottomSheet<void>(
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

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BottomSheetHeader(title: s.playbackAudioEffects, showCloseButton: true),
        const Divider(height: 1),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
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
                const SizedBox(height: 12),
                _AudioEffectsSection(
                  storageKey: 'audio-effects-equalizer',
                  title: s.audioEffectsEqualizer,
                  resetSemanticLabel: s.audioEffectsResetNamed(
                    s.audioEffectsEqualizer,
                  ),
                  resetLabel: s.audioEffectsResetModule,
                  onReset: notifier.resetEqualizer,
                  enabled: settings.equalizerEnabled,
                  onEnabledChanged: notifier.setEqualizerEnabled,
                  initiallyExpanded: true,
                  children: [
                    DropdownButtonFormField<EqualizerPreset>(
                      key: ValueKey(settings.preset),
                      initialValue: settings.preset,
                      isExpanded: true,
                      isDense: false,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: s.audioEffectsCustom,
                      ),
                      items: [
                        for (final preset in EqualizerPreset.values)
                          DropdownMenuItem(
                            value: preset,
                            child: Text(presets[preset.index]),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) notifier.setPreset(value);
                      },
                    ),
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      key: const PageStorageKey('audio-effects-bands'),
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var i = 0; i < 10; i++)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(end: 4),
                              child: SizedBox(
                                width: 44,
                                child: _VerticalEffectSlider(
                                  sliderKey: ValueKey('audio-effects-band-$i'),
                                  label:
                                      AudioEffectsSettings.frequencies[i] < 1000
                                      ? '${AudioEffectsSettings.frequencies[i]} Hz'
                                      : '${AudioEffectsSettings.frequencies[i] ~/ 1000} kHz',
                                  value: settings.gains[i],
                                  formatted:
                                      '${settings.gains[i].toStringAsFixed(1)} dB',
                                  onChanged: (value) =>
                                      notifier.setBand(i, value),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _AudioEffectsSection(
                  storageKey: 'audio-effects-channel',
                  title: s.audioEffectsChannel,
                  resetSemanticLabel: s.audioEffectsResetNamed(
                    s.audioEffectsChannel,
                  ),
                  resetLabel: s.audioEffectsResetModule,
                  onReset: notifier.resetChannel,
                  children: [
                    DropdownButtonFormField<AudioChannelMode>(
                      key: ValueKey(settings.channelMode),
                      initialValue: settings.channelMode,
                      isExpanded: true,
                      isDense: false,
                      decoration: InputDecoration(
                        labelText: s.audioEffectsChannel,
                      ),
                      items: [
                        for (final mode in AudioChannelMode.values)
                          DropdownMenuItem(
                            value: mode,
                            child: Text(modes[mode.index]),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) notifier.setChannelMode(value);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _AudioEffectsSection(
                  storageKey: 'audio-effects-scene',
                  title: s.audioEffectsScene,
                  resetSemanticLabel: s.audioEffectsResetNamed(
                    s.audioEffectsScene,
                  ),
                  resetLabel: s.audioEffectsResetModule,
                  onReset: notifier.resetScene,
                  enabled: settings.sceneEnabled,
                  onEnabledChanged: notifier.setSceneEnabled,
                  children: [
                    DropdownButtonFormField<AudioScene>(
                      key: ValueKey(settings.scene),
                      initialValue: settings.scene,
                      isExpanded: true,
                      isDense: false,
                      decoration: InputDecoration(
                        labelText: s.audioEffectsScene,
                      ),
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
                    const SizedBox(height: 12),
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
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              onPressed: notifier.resetAll,
              child: Text(s.audioEffectsResetAll),
            ),
          ),
        ),
      ],
    );
  }
}

class _AudioEffectsSection extends StatelessWidget {
  const _AudioEffectsSection({
    required this.storageKey,
    required this.title,
    required this.resetSemanticLabel,
    required this.resetLabel,
    required this.onReset,
    required this.children,
    this.enabled,
    this.onEnabledChanged,
    this.initiallyExpanded = false,
  });

  final String storageKey;
  final String title;
  final String resetSemanticLabel;
  final String resetLabel;
  final VoidCallback onReset;
  final List<Widget> children;
  final bool? enabled;
  final ValueChanged<bool>? onEnabledChanged;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: ExpansionTile(
      key: PageStorageKey(storageKey),
      initiallyExpanded: initiallyExpanded,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(title),
      trailing: enabled == null
          ? null
          : Semantics(
              label: title,
              child: Switch.adaptive(
                value: enabled!,
                onChanged: onEnabledChanged,
              ),
            ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        ...children,
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Semantics(
            label: resetSemanticLabel,
            button: true,
            onTap: onReset,
            excludeSemantics: true,
            child: TextButton(onPressed: onReset, child: Text(resetLabel)),
          ),
        ),
      ],
    ),
  );
}

class _VerticalEffectSlider extends StatelessWidget {
  const _VerticalEffectSlider({
    required this.sliderKey,
    required this.label,
    required this.value,
    required this.formatted,
    required this.onChanged,
  });

  final Key sliderKey;
  final String label;
  final double value;
  final String formatted;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        formatted,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      RotatedBox(
        quarterTurns: 3,
        child: SizedBox(
          width: 128,
          height: 44,
          child: Semantics(
            label: label,
            child: Slider(
              key: sliderKey,
              value: value,
              min: -15,
              max: 15,
              divisions: 60,
              label: formatted,
              onChanged: onChanged,
              semanticFormatterCallback: (value) =>
                  '${value.toStringAsFixed(1)} dB',
            ),
          ),
        ),
      ),
      Text(
        label,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
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
