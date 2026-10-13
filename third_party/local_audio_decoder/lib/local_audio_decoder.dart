import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const int _errorCapacity = 512;

final DynamicLibrary _library = _openLibrary();

DynamicLibrary _openLibrary() {
  const libraryName = 'local_audio_decoder';
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('$libraryName.framework/$libraryName');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$libraryName.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('$libraryName.dll');
  }
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

typedef _OpenNative = Int32 Function(
  Pointer<Uint8>,
  Uint32,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
  Uint32,
);
typedef _OpenDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
  int,
);

typedef _ReadNative = Int32 Function(
  Pointer<Void>,
  Pointer<Float>,
  Uint64,
  Pointer<Uint64>,
  Pointer<Uint8>,
  Uint32,
);
typedef _ReadDart = int Function(
  Pointer<Void>,
  Pointer<Float>,
  int,
  Pointer<Uint64>,
  Pointer<Uint8>,
  int,
);

typedef _TotalFramesNative = Int64 Function(Pointer<Void>);
typedef _TotalFramesDart = int Function(Pointer<Void>);
typedef _SampleRateNative = Uint32 Function(Pointer<Void>);
typedef _SampleRateDart = int Function(Pointer<Void>);
typedef _CloseNative = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);

final _OpenDart _openNative = _library
    .lookup<NativeFunction<_OpenNative>>('kiko_audio_decoder_open')
    .asFunction();
final _ReadDart _readNative = _library
    .lookup<NativeFunction<_ReadNative>>('kiko_audio_decoder_read')
    .asFunction();
final _TotalFramesDart _totalFramesNative = _library
    .lookup<NativeFunction<_TotalFramesNative>>(
      'kiko_audio_decoder_total_frames',
    )
    .asFunction();
final _SampleRateDart _sampleRateNative = _library
    .lookup<NativeFunction<_SampleRateNative>>('kiko_audio_decoder_sample_rate')
    .asFunction();
final _CloseDart _closeNative = _library
    .lookup<NativeFunction<_CloseNative>>('kiko_audio_decoder_close')
    .asFunction();

/// A local MP3, WAV, or FLAC decoder that emits mono float32 PCM in chunks.
final class LocalAudioDecoder {
  /// Maximum frames returned by one [read] call (about 65.5 seconds at 16 kHz).
  static const int maxReadFrames = 1 << 20;

  LocalAudioDecoder._(this._handle, this.sampleRate, this.totalFrames);

  /// Opens a local audio file and converts it to mono float32 PCM.
  factory LocalAudioDecoder.open(String path, {int sampleRate = 16000}) {
    if (path.isEmpty || path.contains('\u0000')) {
      throw ArgumentError.value(path, 'path', 'must be a non-empty filesystem path');
    }
    if (sampleRate < 1 || sampleRate > 0xffffffff) {
      throw RangeError.range(
        sampleRate,
        1,
        0xffffffff,
        'sampleRate',
      );
    }

    final nativePath = path.toNativeUtf8(allocator: calloc);
    final handleOutput = calloc<Pointer<Void>>();
    final error = calloc<Uint8>(_errorCapacity);
    try {
      final status = _openNative(
        nativePath.cast<Uint8>(),
        sampleRate,
        handleOutput,
        error,
        _errorCapacity,
      );
      if (status != 0) {
        final partialHandle = handleOutput.value;
        if (partialHandle != nullptr) {
          _closeNative(partialHandle);
        }
        throw AudioDecoderException(_nativeError(status, error));
      }

      final handle = handleOutput.value;
      return LocalAudioDecoder._(
        handle,
        _sampleRateNative(handle),
        _totalFramesNative(handle),
      );
    } finally {
      calloc.free(error);
      calloc.free(handleOutput);
      calloc.free(nativePath);
    }
  }

  Pointer<Void> _handle;

  /// Output samples per second.
  final int sampleRate;

  /// Total mono output frames at [sampleRate].
  final int totalFrames;

  /// Reads up to [maxFrames] samples and copies only the returned frames.
  /// Returns an empty list at end of file.
  Float32List read(int maxFrames) {
    if (_handle == nullptr) {
      throw StateError('decoder is closed');
    }
    if (maxFrames < 0 || maxFrames > LocalAudioDecoder.maxReadFrames) {
      throw RangeError.range(
        maxFrames,
        0,
        LocalAudioDecoder.maxReadFrames,
        'maxFrames',
      );
    }
    if (maxFrames == 0) {
      return Float32List(0);
    }

    final output = calloc<Float>(maxFrames);
    final framesRead = calloc<Uint64>();
    final error = calloc<Uint8>(_errorCapacity);
    try {
      final status = _readNative(
        _handle,
        output,
        maxFrames,
        framesRead,
        error,
        _errorCapacity,
      );
      if (status != 0) {
        throw AudioDecoderException(_nativeError(status, error));
      }
      return Float32List.fromList(output.asTypedList(framesRead.value));
    } finally {
      calloc.free(error);
      calloc.free(framesRead);
      calloc.free(output);
    }
  }

  /// Releases the native decoder. Calling this more than once is safe.
  void close() {
    if (_handle != nullptr) {
      _closeNative(_handle);
      _handle = nullptr;
    }
  }
}

/// An error reported while opening or decoding a supported audio file.
final class AudioDecoderException implements Exception {
  const AudioDecoderException(this.message);

  /// Human-readable native decoder error.
  final String message;

  @override
  String toString() => 'AudioDecoderException: $message';
}

String _nativeError(int status, Pointer<Uint8> error) {
  final message = error.cast<Utf8>().toDartString();
  return message.isEmpty ? 'native decoder failed with status $status' : message;
}
