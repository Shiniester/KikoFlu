import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart';
import 'package:just_audio_media_kit/mpv_client.dart';
import 'package:media_kit/generated/libmpv/bindings.dart';
import 'package:media_kit/media_kit.dart';
import '../models/audio_effects_settings.dart';
import 'audio_effects_templates.dart';

enum AudioEffectsStatus { waiting, ready, passthrough, unavailable }

/// Source snapshots and hot controls share the same validated native templates.
class AudioEffectsGraph {
  static const sceneNames = ['bathroom', 'through_wall', 'telephone'];

  // One native target carries the mode and amount into the same audio sample.
  static double _sceneTarget(AudioEffectsSettings settings) =>
      settings.sceneEnabled && settings.sceneAmount > 0
      ? 2.0 * settings.scene.index + settings.sceneAmount / 100
      : 0;

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

  static List<String> activeModules(AudioEffectsSettings settings) => [
    if (settings.equalizerActive) 'eq',
    if (settings.channelActive) 'channel',
    if (settings.binauralActive) 'binaural',
    if (settings.needsGuard) 'guard',
    if (settings.sceneActive) 'scene',
    if (settings.sceneActive) sceneNames[settings.scene.index],
  ];

  static String render(
    AudioEffectsSettings settings, {
    required bool systemLibrary,
    int? resetToken,
  }) {
    final modules = activeModules(settings);
    if (modules.isEmpty) return '';
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
      'scene': templates['scene']!.replaceAll(
        '__SCENE__',
        '${_sceneTarget(settings)}',
      ),
      for (final name in sceneNames) name: templates[name]!,
    };
    return 'format=channels=stereo,${modules.map((name) {
      final graph = resetToken == null ? graphs[name]! : '${graphs[name]}'
                ';[out]volume@kiko_reset$resetToken=1:precision=double[reset]';
      return '@kiko_$name:lavfi=o=[threads=1]:graph=%${graph.length}%$graph';
    }).join(',')}';
  }

  static List<List<String>> controls(
    AudioEffectsSettings settings, {
    AudioEffectsSettings? previous,
  }) {
    final gains = settings.effectiveGains;
    final oldGains = previous?.effectiveGains;
    final sceneTarget = _sceneTarget(settings);
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
      if (settings.equalizerActive)
        for (var i = 0; i < 10; i++) ...[
          if (oldGains == null || gains[i] != oldGains[i])
            [
              'af-command',
              'kiko_eq',
              'g',
              '${gains[i]}',
              'equalizer@eq_band$i',
            ],
          if (oldGains == null || (gains[i] == 0) != (oldGains[i] == 0))
            [
              'af-command',
              'kiko_eq',
              'enable',
              gains[i] == 0 ? '0' : '1',
              'equalizer@eq_band$i',
            ],
        ],
      if (settings.channelActive &&
          previous?.channelMode != settings.channelMode)
        [
          'af-command',
          'kiko_channel',
          'volume',
          '${settings.channelMode.index}',
          'volume@channel_mode',
        ],
      // Stop the outgoing target first; native sample ramps pass through neutral.
      if (settings.binauralActive)
        for (final (amount, oldAmount, target) in binauralTargets)
          if (amount == 0 && oldAmount != 0)
            ['af-command', 'kiko_binaural', 'volume', '0', target],
      if (settings.binauralActive)
        for (final (amount, oldAmount, target) in binauralTargets)
          if (amount > 0 && amount != oldAmount)
            ['af-command', 'kiko_binaural', 'volume', '$amount', target],
      if (settings.sceneActive &&
          (previous == null || sceneTarget != _sceneTarget(previous)))
        [
          'af-command',
          'kiko_scene',
          'volume',
          '$sceneTarget',
          'volume@scene_amount',
        ],
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
  List<String> _installedModules = const [];
  int _resetGeneration = 0;
  bool _graphInstalled = false;
  bool _passthrough = false;
  bool _failed = false;
  bool _pendingControls = false;
  // Android and Apple libmpv builds do not enumerate libavfilter choices.
  final bool _checkFilterSupport =
      defaultTargetPlatform == TargetPlatform.linux || Platform.isWindows;
  StreamSubscription<PlayerLog>? _logs;
  StreamSubscription<Duration>? _position;
  _AudioOutputObserver? _output;

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
      await player.waitForPlayerInitialization;
      if (player.disposed) return;
      _player = player;
      _failed = false;
      _output = _AudioOutputObserver.attach(player, _apply);
      if (_output == null) {
        _markUnavailable();
        return;
      }
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
    _output?.beginSource();
    _install();
  }

  void resetHistory() {
    if (!_failed && _graphInstalled) _install(mayReuseFilters: true);
  }

  void _install({bool mayReuseFilters = false}) {
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
    // The stereo DSP chain changes the layout of a neutral multichannel source.
    final modules = AudioEffectsGraph.activeModules(_settings);
    final installGraph = !_passthrough && modules.isNotEmpty;
    // A seek must change each active lavfi graph so mpv recreates stateful filters.
    final resetToken = mayReuseFilters && installGraph
        ? ++_resetGeneration
        : null;
    final result = _setAf(
      player,
      installGraph
          ? AudioEffectsGraph.render(
              _settings,
              systemLibrary: false,
              resetToken: resetToken,
            )
          : '',
    );
    if (result < 0) {
      _markUnavailable();
    } else {
      _graphInstalled = installGraph;
      _installedModules = installGraph ? modules : const [];
      _appliedSettings = _settings;
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
    final modules = AudioEffectsGraph.activeModules(_settings);
    if (!listEquals(modules, _installedModules)) {
      _install();
      return;
    }
    final controls = _graphInstalled
        ? AudioEffectsGraph.controls(_settings, previous: _appliedSettings)
        : const <List<String>>[];
    if (controls.isEmpty && _output?.hasAudioOutput != true) {
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
          _appliedSettings = null;
          _pendingControls = true;
          if (allowInitialSnapshot && _output?.hasAudioOutput != true) {
            _install(mayReuseFilters: true);
          }
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
    _graphInstalled = false;
    _installedModules = const [];
    _appliedSettings = null;
    _pendingControls = false;
    final player = _player;
    if (player != null && !player.disposed) _setAf(player, '');
    onStatus(AudioEffectsStatus.unavailable);
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
    _output?.dispose();
    _output = null;
    _player?.onLoadHooks.remove(_onLoad);
    _player = null;
    await _logs?.cancel();
    _logs = null;
    await _position?.cancel();
    _position = null;
    _graphInstalled = false;
    _installedModules = const [];
    _appliedSettings = null;
    _pendingControls = false;
  }

  Future<void> dispose() => _detach();
}

class _AudioOutputObserver {
  _AudioOutputObserver(this._onChange);

  static _AudioOutputObserver? attach(
    NativePlayer player,
    VoidCallback onChange,
  ) {
    final observer = _AudioOutputObserver(onChange);
    try {
      observer._client = MpvClient(
        player,
        'audio-effects',
        onEvent: observer._handleEvent,
        onDrained: observer._handleDrained,
      );
    } on StateError {
      return null;
    }
    for (final (id, property) in ['audio-params', 'audio-out-params'].indexed) {
      final result = observer._client.observe(
        property,
        id,
        mpv_format.MPV_FORMAT_NODE,
      );
      if (result < 0) {
        observer.dispose();
        return null;
      }
    }
    return observer;
  }

  final VoidCallback _onChange;
  late final MpvClient _client;
  final _available = [false, false];
  bool _sourceRestarted = true;
  bool _changed = false;

  bool get hasAudioOutput =>
      _sourceRestarted && _available.every((available) => available);

  void beginSource() => _sourceRestarted = false;

  void _handleEvent(mpv_event event) {
    switch (event.event_id) {
      case mpv_event_id.MPV_EVENT_PROPERTY_CHANGE:
        final property = event.data.cast<mpv_event_property>().ref;
        _available[event.reply_userdata] =
            property.format == mpv_format.MPV_FORMAT_NODE;
        _changed = true;
      case mpv_event_id.MPV_EVENT_PLAYBACK_RESTART:
        _sourceRestarted = true;
        _changed = true;
      case mpv_event_id.MPV_EVENT_AUDIO_RECONFIG:
        _changed = true;
    }
  }

  void _handleDrained() {
    if (!_changed) return;
    _changed = false;
    _onChange();
  }

  void dispose() => _client.dispose();
}
