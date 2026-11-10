import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';
import '../models/audio_effects_settings.dart';
import 'audio_effects_templates.dart';

enum AudioEffectsStatus { waiting, ready, passthrough, unavailable }

/// Source snapshots and hot controls share the same validated native templates.
class AudioEffectsGraph {
  static const sceneNames = ['bathroom', 'through_wall', 'telephone'];

  static bool supportsFilterGraph(String? choices, String? version) {
    final parts = RegExp(r'(\d+)\.(\d+)').firstMatch(version ?? '');
    if (parts != null) {
      final major = int.parse(parts[1]!);
      final minor = int.parse(parts[2]!);
      if (major < 4 || (major == 4 && minor < 4)) return false;
    }
    final available = (choices ?? '').split(',').toSet();
    return const [
      'aeval',
      'aformat',
      'alimiter',
      'asendcmd',
      'equalizer',
      'biquad',
      'volume',
      'asetpts',
    ].every(available.contains);
  }

  /// Returns L/R plus a sample-aligned envelope consumed only by the next guard.
  static String binaural(AudioEffectsSettings settings) =>
      nativeAudioEffectsTemplates['binaural']!
          .replaceAll('__STEREO__', '${settings.effectiveStereoAmount}')
          .replaceAll('__MONO__', '${settings.effectiveMonoAmount}');

  static String render(
    AudioEffectsSettings settings, {
    required bool systemLibrary,
  }) {
    final templates = systemLibrary
        ? systemAudioEffectsTemplates
        : nativeAudioEffectsTemplates;
    var eq = templates['eq']!;
    for (var i = 0; i < 10; i++) {
      final gain = settings.effectiveGains[i];
      eq = eq
          .replaceAll('__GAIN${i}__', '$gain')
          .replaceAll('__ENABLE${i}__', gain == 0 ? '0' : '1');
    }
    final mode = settings.channelMode.index;
    final channel = templates['channel']!.replaceAll('__MODE__', '$mode');
    final graphs = <String, String>{
      'eq': eq,
      'channel': channel,
      'binaural': binaural(settings),
      'guard': templates['guard']!.replaceAll(
        '__GUARD__',
        settings.needsGuard ? '1' : '0',
      ),
      for (var i = 0; i < sceneNames.length; i++)
        sceneNames[i]: templates[sceneNames[i]]!.replaceAll(
          '__AMOUNT__',
          settings.sceneEnabled && settings.scene.index == i
              ? '${settings.sceneAmount / 100}'
              : '0',
        ),
    };
    return 'format=channels=stereo,${graphs.entries.map((e) => '@kiko_${e.key}:lavfi=o=[threads=1]:graph=%${e.value.length}%${e.value}').join(',')}';
  }

  static List<List<String>> controls(
    AudioEffectsSettings settings, {
    AudioEffectsSettings? previous,
  }) {
    final gains = settings.effectiveGains;
    final oldGains = previous?.effectiveGains;
    double sceneAmount(AudioEffectsSettings value, int index) =>
        value.sceneEnabled && value.scene.index == index
        ? value.sceneAmount / 100
        : 0;
    final binauralTargets = [
      (
        settings.effectiveStereoAmount,
        previous?.effectiveStereoAmount,
        'volume@stereo_amount',
      ),
      (
        settings.effectiveMonoAmount,
        previous?.effectiveMonoAmount,
        'volume@mono_amount',
      ),
    ];
    return [
      // Enable the guard before EQ or widening can raise the output level.
      // Even EQ cuts can overshoot on transients.
      if (settings.needsGuard && previous?.needsGuard != true)
        ['af-command', 'kiko_guard', 'volume', '1', 'volume@guard_mix'],
      for (var i = 0; i < 10; i++) ...[
        if (oldGains == null || gains[i] != oldGains[i])
          ['af-command', 'kiko_eq', 'g', '${gains[i]}', 'equalizer@eq_band$i'],
        if (oldGains == null || (gains[i] == 0) != (oldGains[i] == 0))
          [
            'af-command',
            'kiko_eq',
            'enable',
            gains[i] == 0 ? '0' : '1',
            'equalizer@eq_band$i',
          ],
      ],
      if (previous?.channelMode != settings.channelMode)
        [
          'af-command',
          'kiko_channel',
          'volume',
          '${settings.channelMode.index}',
          'volume@channel_mode',
        ],
      // Stop the outgoing target first; native sample ramps pass through neutral.
      for (final (amount, oldAmount, target) in binauralTargets)
        if (amount == 0 && oldAmount != 0)
          ['af-command', 'kiko_binaural', 'volume', '0', target],
      for (final (amount, oldAmount, target) in binauralTargets)
        if (amount > 0 && amount != oldAmount)
          ['af-command', 'kiko_binaural', 'volume', '$amount', target],
      for (var i = 0; i < sceneNames.length; i++)
        if (previous == null ||
            sceneAmount(previous, i) != sceneAmount(settings, i))
          [
            'af-command',
            'kiko_${sceneNames[i]}',
            'volume',
            '${sceneAmount(settings, i)}',
            'volume@scene_amount',
          ],
      if (!settings.needsGuard && previous?.needsGuard != false)
        ['af-command', 'kiko_guard', 'volume', '0', 'volume@guard_mix'],
    ];
  }
}

/// Owns only the service's native audio instance; video is never addressed.
class NativeAudioEffects {
  NativeAudioEffects(this.onStatus);
  final void Function(AudioEffectsStatus) onStatus;
  NativePlayer? _player;
  AudioEffectsSettings _settings = AudioEffectsSettings();
  AudioEffectsSettings? _appliedSettings;
  bool _passthrough = false;
  bool _failed = false;
  bool _pendingControls = false;
  // Android and Apple libmpv builds do not enumerate libavfilter choices.
  final bool _checkFilterSupport =
      defaultTargetPlatform == TargetPlatform.linux || Platform.isWindows;
  StreamSubscription<PlayerLog>? _logs;
  StreamSubscription<Duration>? _position;
  StreamSubscription<AudioParams>? _params;

  Future<void> configure(
    NativePlayer player,
    AudioEffectsSettings settings,
    bool passthrough,
  ) async {
    _settings = settings;
    final changedOutput = passthrough != _passthrough;
    _passthrough = passthrough;
    if (!identical(player, _player)) {
      await _detach();
      _player = player;
      _failed = false;
      player.onLoadHooks.add(_onLoad);
      _position = player.stream.position.listen((_) {
        if (_pendingControls) _apply();
      });
      _logs = player.stream.log.listen((log) {
        if ((log.level == 'error' || log.level == 'fatal') &&
            (log.text.contains('parsing the filter graph failed') ||
                log.text.contains('No such filter'))) {
          _markUnavailable();
        }
      });
      _params = player.stream.audioParams.listen((_) => _apply());
      await player.observeProperty('seeking', (value) async {
        if (value == 'no' || value == 'false') _apply();
      });
      await player.observeProperty('audio-out-params', (_) async => _apply());
      _install();
    } else if (changedOutput) {
      _failed = false;
      _install();
    } else {
      _apply(allowInitialSnapshot: true);
    }
    if (_passthrough) onStatus(AudioEffectsStatus.passthrough);
  }

  Future<void> _onLoad() async {
    _failed = false;
    _install();
  }

  void resetHistory() {
    if (!_failed) _install();
  }

  void _install() {
    final player = _player;
    if (player == null || player.disposed) return;
    // Reject incomplete filter lists before loading the first track.
    if (_checkFilterSupport &&
        !_passthrough &&
        !AudioEffectsGraph.supportsFilterGraph(
          _property(player, 'option-info/af/choices'),
          _property(player, 'ffmpeg-version'),
        )) {
      _markUnavailable();
      return;
    }
    final result = _setAf(
      player,
      _passthrough
          ? ''
          : AudioEffectsGraph.render(_settings, systemLibrary: false),
    );
    if (result < 0) {
      _markUnavailable();
    } else {
      _appliedSettings ??= _settings;
      _pendingControls = !_passthrough;
      onStatus(
        _passthrough
            ? AudioEffectsStatus.passthrough
            : AudioEffectsStatus.waiting,
      );
    }
  }

  int _setAf(NativePlayer player, String graph) {
    final name = 'af'.toNativeUtf8();
    final value = graph.toNativeUtf8();
    try {
      return player.mpv.mpv_set_property_string(
        player.ctx,
        name.cast(),
        value.cast(),
      );
    } finally {
      calloc.free(name);
      calloc.free(value);
    }
  }

  void _apply({bool allowInitialSnapshot = false}) {
    final player = _player;
    if (player == null || player.disposed || _passthrough || _failed) return;
    final controls = AudioEffectsGraph.controls(
      _settings,
      previous: _appliedSettings,
    );
    if (controls.isEmpty && !_hasAudioOutput(player)) {
      _pendingControls = true;
      return;
    }
    for (final command in controls) {
      var result = _command(player, command);
      if (result == -12) {
        result = _command(player, [
          ...command.take(4),
          command.last.split('@').last,
        ]);
      }
      if (result < 0) {
        // Targets can be absent while loading, seeking, or reconfiguring output.
        if (result == -12) {
          _pendingControls = true;
          if (allowInitialSnapshot && !_hasAudioOutput(player)) _install();
          return;
        }
        _markUnavailable();
        return;
      }
    }
    _appliedSettings = _settings;
    _pendingControls = false;
    onStatus(AudioEffectsStatus.ready);
  }

  void _markUnavailable() {
    if (_failed || _passthrough) return;
    _failed = true;
    _pendingControls = false;
    final player = _player;
    if (player != null && !player.disposed) _setAf(player, '');
    onStatus(AudioEffectsStatus.unavailable);
  }

  bool _hasAudioOutput(NativePlayer player) {
    return _property(player, 'audio-out-params') != null;
  }

  String? _property(NativePlayer player, String property) {
    final name = property.toNativeUtf8();
    try {
      final value = player.mpv.mpv_get_property_string(player.ctx, name.cast());
      if (value == nullptr) return null;
      try {
        return value.cast<Utf8>().toDartString();
      } finally {
        player.mpv.mpv_free(value.cast());
      }
    } finally {
      calloc.free(name);
    }
  }

  // NativePlayer.command discards the status needed for exact-target retry.
  int _command(NativePlayer player, List<String> command) {
    final strings = command.map((value) => value.toNativeUtf8()).toList();
    final argv = calloc<Pointer<Int8>>(strings.length + 1);
    try {
      for (var i = 0; i < strings.length; i++) {
        argv[i] = strings[i].cast();
      }
      return player.mpv.mpv_command(player.ctx, argv);
    } finally {
      for (final value in strings) {
        calloc.free(value);
      }
      calloc.free(argv);
    }
  }

  Future<void> _detach() async {
    await _params?.cancel();
    _params = null;
    await _logs?.cancel();
    _logs = null;
    await _position?.cancel();
    _position = null;
    _appliedSettings = null;
    _pendingControls = false;
    final player = _player;
    _player = null;
    if (player == null) return;
    player.onLoadHooks.remove(_onLoad);
    if (!player.disposed) await player.unobserveProperty('seeking');
    if (!player.disposed) await player.unobserveProperty('audio-out-params');
  }

  Future<void> dispose() => _detach();
}
