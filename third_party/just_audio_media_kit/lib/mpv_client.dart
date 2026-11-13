import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;

class MpvClient {
  MpvClient(
    this._player,
    String name, {
    void Function(mpv_event)? onEvent,
    void Function()? onDrained,
  })  : _onEvent = onEvent,
        _onDrained = onDrained {
    final clientName = name.toNativeUtf8();
    try {
      _handle = _mpv.mpv_create_weak_client(_player.ctx, clientName.cast());
    } finally {
      calloc.free(clientName);
    }
    if (_handle == nullptr) throw StateError('Cannot create mpv client $name');
    _wakeup = NativeCallable<Void Function(Pointer<Void>)>.listener(
        (Pointer<Void> _) => _drain());
    _mpv.mpv_set_wakeup_callback(_handle, _wakeup.nativeFunction, nullptr);
    _player.release.add(_release);
  }

  final NativePlayer _player;
  final void Function(mpv_event)? _onEvent;
  final void Function()? _onDrained;
  late final Pointer<mpv_handle> _handle;
  late final NativeCallable<Void Function(Pointer<Void>)> _wakeup;
  final _pending = <int, Completer<String>>{};
  int _nextRequest = 0;
  bool _disposed = false;

  MPV get _mpv => _player.mpv;

  int observe(String property, int id, int format) {
    final name = property.toNativeUtf8();
    try {
      return _mpv.mpv_observe_property(_handle, id, name.cast(), format);
    } finally {
      calloc.free(name);
    }
  }

  Future<String> read(String property) async {
    if (_disposed) return '';
    final request = ++_nextRequest;
    final completion = _pending[request] = Completer<String>();
    final name = property.toNativeUtf8();
    try {
      final result = _mpv.mpv_get_property_async(
        _handle,
        request,
        name.cast(),
        mpv_format.MPV_FORMAT_STRING,
      );
      if (result < 0) {
        _pending.remove(request);
        throw StateError('Cannot read mpv property $property: $result');
      }
    } finally {
      calloc.free(name);
    }
    return completion.future;
  }

  void _drain() {
    while (!_disposed) {
      final event = _mpv.mpv_wait_event(_handle, 0).ref;
      switch (event.event_id) {
        case mpv_event_id.MPV_EVENT_NONE:
          _onDrained?.call();
          return;
        case mpv_event_id.MPV_EVENT_SHUTDOWN:
          dispose();
          return;
        case mpv_event_id.MPV_EVENT_GET_PROPERTY_REPLY:
          final completion = _pending.remove(event.reply_userdata);
          if (completion == null) continue;
          if (event.error < 0 || event.data == nullptr) {
            completion.complete('');
          } else {
            final property = event.data.cast<mpv_event_property>().ref;
            completion.complete(
              property.format == mpv_format.MPV_FORMAT_STRING
                  ? property.data.cast<Pointer<Utf8>>().value.toDartString()
                  : '',
            );
          }
        default:
          _onEvent?.call(event);
      }
    }
  }

  Future<void> _release() async => dispose();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_player.disposed) _player.release.remove(_release);
    _mpv.mpv_set_wakeup_callback(_handle, nullptr, nullptr);
    _mpv.mpv_destroy(_handle);
    _wakeup.close();
    for (final completion in _pending.values) {
      completion.complete('');
    }
    _pending.clear();
  }
}
