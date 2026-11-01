import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:path/path.dart' as p;

const _sampleRate = 16000;
const _loadRequest = 1;
const _stopRequest = 2;
const _durationRequest = 3;
const _idleRequest = 4;
const _pollDelay = Duration(milliseconds: 10);
const _noOutputTimeout = Duration(seconds: 60);

/// Decodes local audio through a separate libmpv instance and a bounded pipe.
final class MpvAudioDecoder {
  MpvAudioDecoder._(this._mpv, this._handle, this._pipe);

  /// Starts decoding without connecting the instance to the audio device.
  factory MpvAudioDecoder.open(String path) {
    if (path.isEmpty || path.contains('\u0000')) {
      throw ArgumentError.value(path, 'path', 'must be a non-empty path');
    }

    final pipe = _PcmPipe.create();
    mpv.MPV? library;
    Pointer<mpv.mpv_handle> handle = nullptr;
    try {
      // NativeLibrary's resolved path is isolate-local.
      NativeLibrary.ensureInitialized();
      library = mpv.MPV(DynamicLibrary.open(NativeLibrary.path));
      handle = library.mpv_create();
      if (handle == nullptr) throw StateError('Could not create libmpv.');
      final decoder = MpvAudioDecoder._(library, handle, pipe);
      for (final option in <String, String>{
        'config': 'no',
        'terminal': 'no',
        'idle': 'yes',
        'video': 'no',
        'gapless-audio': 'yes',
        'ao': 'pcm',
        'ao-pcm-file': pipe.path,
        'ao-pcm-waveheader': 'no',
        'audio-samplerate': '$_sampleRate',
        'audio-channels': 'mono',
        'audio-format': 'float',
      }.entries) {
        decoder._setOption(option.key, option.value);
      }
      decoder._check(library.mpv_initialize(handle), 'initialize libmpv');
      decoder._command(['loadfile', path, 'replace'], _loadRequest);
      return decoder;
    } catch (_) {
      if (handle != nullptr) library!.mpv_terminate_destroy(handle);
      pipe.close();
      rethrow;
    }
  }

  final mpv.MPV _mpv;
  final Pointer<mpv.mpv_handle> _handle;
  final _PcmPipe _pipe;
  bool _ended = false;
  bool _fileStarted = false;
  bool _stopReplied = false;
  bool _closed = false;
  int _framesRead = 0;
  String? _failure;

  /// Estimated output length. It is used for progress, never to truncate audio.
  int totalFrames = 0;

  /// Reads at most [maxFrames] mono samples, or an empty list at end of file.
  Future<Float32List> read(
    int maxFrames, {
    void Function()? checkCancelled,
  }) async {
    if (_closed) throw StateError('decoder is closed');
    if (maxFrames < 0 || maxFrames > 1 << 20) {
      throw RangeError.range(maxFrames, 0, 1 << 20, 'maxFrames');
    }
    if (maxFrames == 0) return Float32List(0);

    final bytes = Uint8List(maxFrames * sizeOf<Float>());
    var count = 0;
    var lastOutput = DateTime.now();
    while (count < bytes.length) {
      checkCancelled?.call();
      _readEvents();
      if (_failure case final failure?) throw StateError(failure);

      final received = _pipe.read(bytes, count);
      if (received > 0) {
        count += received;
        lastOutput = DateTime.now();
        continue;
      }
      if (_ended) {
        if (count == 0 && _framesRead == 0) {
          throw StateError('libmpv produced no audio samples.');
        }
        break;
      }
      if (DateTime.now().difference(lastOutput) > _noOutputTimeout) {
        throw StateError('libmpv stopped producing audio samples.');
      }
      await Future<void>.delayed(_pollDelay);
    }
    final samples = _samples(bytes, count);
    _framesRead += samples.length;
    return samples;
  }

  /// Stops the writer while continuing to drain the pipe, then releases it.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      if (!_ended) {
        _command(['stop'], _stopRequest);
        final discard = Uint8List(65536);
        while (!_ended && !(_stopReplied && !_fileStarted)) {
          _readEvents();
          if (_ended || (_stopReplied && !_fileStarted)) break;
          if (_pipe.read(discard, 0) == 0) {
            await Future<void>.delayed(_pollDelay);
          } else {
            await Future<void>.delayed(Duration.zero);
          }
        }
      }
    } finally {
      try {
        _mpv.mpv_terminate_destroy(_handle);
      } finally {
        _pipe.close();
      }
    }
  }

  void _setOption(String name, String value) {
    final nativeName = name.toNativeUtf8();
    final nativeValue = value.toNativeUtf8();
    try {
      _check(
        _mpv.mpv_set_option_string(
          _handle,
          nativeName.cast(),
          nativeValue.cast(),
        ),
        'set libmpv option $name',
      );
    } finally {
      malloc.free(nativeValue);
      malloc.free(nativeName);
    }
  }

  void _command(List<String> arguments, int request) {
    final nativeArguments = calloc<Pointer<Int8>>(arguments.length + 1);
    try {
      for (var i = 0; i < arguments.length; i++) {
        nativeArguments[i] = arguments[i].toNativeUtf8().cast();
      }
      _check(
        _mpv.mpv_command_async(_handle, request, nativeArguments),
        'send libmpv ${arguments.first} command',
      );
    } finally {
      for (var i = 0; i < arguments.length; i++) {
        if (nativeArguments[i] != nullptr) malloc.free(nativeArguments[i]);
      }
      calloc.free(nativeArguments);
    }
  }

  void _readEvents() {
    while (true) {
      final event = _mpv.mpv_wait_event(_handle, 0).ref;
      if (event.event_id == mpv.mpv_event_id.MPV_EVENT_NONE) return;
      if (event.event_id == mpv.mpv_event_id.MPV_EVENT_SHUTDOWN) {
        _ended = true;
        _failure ??= 'libmpv shut down while decoding.';
      } else if (event.event_id == mpv.mpv_event_id.MPV_EVENT_START_FILE) {
        _fileStarted = true;
      } else if (event.event_id == mpv.mpv_event_id.MPV_EVENT_FILE_LOADED) {
        final name = 'duration'.toNativeUtf8();
        try {
          _mpv.mpv_get_property_async(
            _handle,
            _durationRequest,
            name.cast(),
            mpv.mpv_format.MPV_FORMAT_DOUBLE,
          );
        } finally {
          malloc.free(name);
        }
      } else if (event.event_id ==
              mpv.mpv_event_id.MPV_EVENT_GET_PROPERTY_REPLY &&
          event.reply_userdata == _durationRequest &&
          event.error >= 0 &&
          event.data != nullptr) {
        final property = event.data.cast<mpv.mpv_event_property>().ref;
        if (property.format == mpv.mpv_format.MPV_FORMAT_DOUBLE &&
            property.data != nullptr) {
          final seconds = property.data.cast<Double>().value;
          if (seconds.isFinite && seconds > 0) {
            totalFrames = (seconds * _sampleRate).round();
          }
        }
      } else if (event.event_id == mpv.mpv_event_id.MPV_EVENT_COMMAND_REPLY) {
        if (event.reply_userdata == _stopRequest && event.error >= 0) {
          _stopReplied = true;
        }
        if (event.reply_userdata == _loadRequest && event.error < 0) {
          _failure = 'Could not load audio: ${_error(event.error)}';
          _ended = true;
        }
      } else if (event.event_id == mpv.mpv_event_id.MPV_EVENT_END_FILE) {
        if (event.data != nullptr) {
          final end = event.data.cast<mpv.mpv_event_end_file>().ref;
          if (end.reason != mpv.mpv_end_file_reason.MPV_END_FILE_REASON_EOF &&
              !_closed) {
            _failure = 'Could not decode audio: ${_error(end.error)}';
          }
        } else if (!_closed) {
          _failure = 'libmpv ended audio without a reason.';
        }
        final name = 'idle-active'.toNativeUtf8();
        try {
          _check(
            _mpv.mpv_observe_property(
              _handle,
              _idleRequest,
              name.cast(),
              mpv.mpv_format.MPV_FORMAT_FLAG,
            ),
            'observe libmpv idle state',
          );
        } finally {
          malloc.free(name);
        }
      } else if (event.event_id == mpv.mpv_event_id.MPV_EVENT_PROPERTY_CHANGE &&
          event.reply_userdata == _idleRequest &&
          event.data != nullptr) {
        final property = event.data.cast<mpv.mpv_event_property>().ref;
        if (property.format == mpv.mpv_format.MPV_FORMAT_FLAG &&
            property.data != nullptr &&
            property.data.cast<Int32>().value != 0) {
          _ended = true;
        }
      }
    }
  }

  void _check(int status, String operation) {
    if (status < 0) throw StateError('Could not $operation: ${_error(status)}');
  }

  String _error(int status) =>
      _mpv.mpv_error_string(status).cast<Utf8>().toDartString();

  static Float32List _samples(Uint8List bytes, int length) {
    if (length % sizeOf<Float>() != 0) {
      throw StateError('libmpv returned an incomplete PCM sample.');
    }
    return Float32List.view(bytes.buffer, bytes.offsetInBytes, length ~/ 4);
  }

  @visibleForTesting
  static Float32List samplesForTesting(Uint8List bytes) =>
      _samples(bytes, bytes.length);

  @visibleForTesting
  int get bufferedBytesForTesting => (_pipe as _WindowsPipe).availableBytes;
}

abstract class _PcmPipe {
  String get path;
  int read(Uint8List target, int offset);
  void close();

  static _PcmPipe create() =>
      Platform.isWindows ? _WindowsPipe() : _PosixPipe();
}

final class _WindowsPipe implements _PcmPipe {
  _WindowsPipe()
    : _directory = Directory.systemTemp.createTempSync('kiko-pcm-') {
    path = r'\\.\pipe\kikoflu-' + p.basename(_directory.path);
    final nativePath = path.toNativeUtf16();
    try {
      _lastError();
      _handle = _createPipe(nativePath, 1, 1, 1, 65536, 65536, 0, nullptr);
      if (_handle == -1) throw _error('create named pipe');
    } catch (_) {
      _directory.deleteSync();
      rethrow;
    } finally {
      malloc.free(nativePath);
    }
  }

  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _createPipe = _kernel
      .lookupFunction<
        IntPtr Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Uint32,
          Uint32,
          Uint32,
          Uint32,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Utf16>,
          int,
          int,
          int,
          int,
          int,
          int,
          Pointer<Void>,
        )
      >('CreateNamedPipeW');
  static final _connect = _kernel
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Void>),
        int Function(int, Pointer<Void>)
      >('ConnectNamedPipe');
  static final _disconnect = _kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'DisconnectNamedPipe',
      );
  static final _peek = _kernel
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<Void>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
        ),
        int Function(
          int,
          Pointer<Void>,
          int,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
        )
      >('PeekNamedPipe');
  static final _read = _kernel
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
      >('ReadFile');
  static final _close = _kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  static final _lastError = _kernel
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');

  final Directory _directory;
  late final int _handle;
  bool _connected = false;
  @override
  late final String path;

  @override
  int read(Uint8List target, int offset) {
    final available = availableBytes;
    final capacity = target.length - offset;
    final length = available < capacity ? available : capacity;
    if (length == 0) return 0;
    final data = calloc<Uint8>(length);
    final received = calloc<Uint32>();
    try {
      if (_read(_handle, data, length, received, nullptr) == 0) {
        final error = _lastError();
        if (error == 109 || error == 233 || error == 232) {
          _disconnectWriter();
          return 0;
        }
        throw StateError('Could not read PCM pipe: Windows error $error');
      }
      target.setRange(
        offset,
        offset + received.value,
        data.asTypedList(received.value),
      );
      return received.value;
    } finally {
      calloc.free(received);
      calloc.free(data);
    }
  }

  int get availableBytes {
    if (!_connected) {
      if (_connect(_handle, nullptr) != 0) {
        _connected = true;
      } else {
        final error = _lastError();
        if (error == 535 || error == 232) {
          _connected = true;
        } else if (error == 536 || error == 233 || error == 109) {
          return 0;
        } else {
          throw StateError('Could not connect PCM pipe: Windows error $error');
        }
      }
    }
    final available = calloc<Uint32>();
    try {
      if (_peek(_handle, nullptr, 0, nullptr, available, nullptr) == 0) {
        final error = _lastError();
        if (error == 109 || error == 233 || error == 232) {
          _disconnectWriter();
          return 0;
        }
        throw StateError('Could not inspect PCM pipe: Windows error $error');
      }
      return available.value;
    } finally {
      calloc.free(available);
    }
  }

  void _disconnectWriter() {
    if (_connected) {
      _disconnect(_handle);
      _connected = false;
    }
  }

  @override
  void close() {
    _close(_handle);
    _directory.deleteSync();
  }

  StateError _error(String action) =>
      StateError('Could not $action: Windows error ${_lastError()}');
}

final class _PosixPipe implements _PcmPipe {
  _PosixPipe() : _directory = Directory.systemTemp.createTempSync('kiko-pcm-') {
    path = p.join(_directory.path, 'audio');
    final nativePath = path.toNativeUtf8();
    try {
      _errno();
      if (_mkfifo(nativePath, 384) != 0) throw _error('create FIFO');
      _fd = _open(nativePath, Platform.isMacOS || Platform.isIOS ? 4 : 2048);
      if (_fd < 0) throw _error('open FIFO');
    } catch (_) {
      _directory.deleteSync(recursive: true);
      rethrow;
    } finally {
      malloc.free(nativePath);
    }
  }

  static final _libc = DynamicLibrary.process();
  static final _mkfifo = _libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('mkfifo');
  static final _open = _libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('open');
  static final _read = _libc
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, UintPtr),
        int Function(int, Pointer<Uint8>, int)
      >('read');
  static final _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final _errno = _libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        Platform.isMacOS || Platform.isIOS
            ? '__error'
            : Platform.isAndroid
            ? '__errno'
            : '__errno_location',
      );

  final Directory _directory;
  late final int _fd;
  @override
  late final String path;

  @override
  int read(Uint8List target, int offset) {
    final length = target.length - offset;
    final data = calloc<Uint8>(length);
    try {
      final count = _read(_fd, data, length);
      if (count < 0) {
        final error = _errno().value;
        if (error == 4 ||
            error == (Platform.isMacOS || Platform.isIOS ? 35 : 11)) {
          return 0;
        }
        throw StateError('Could not read PCM FIFO: errno $error');
      }
      target.setRange(offset, offset + count, data.asTypedList(count));
      return count;
    } finally {
      calloc.free(data);
    }
  }

  @override
  void close() {
    _close(_fd);
    File(path).deleteSync();
    _directory.deleteSync();
  }

  StateError _error(String action) =>
      StateError('Could not $action: errno ${_errno().value}');
}
