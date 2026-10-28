import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

void setProcessEnvironment(String key, String value) {
  if (Platform.isWindows) {
    final keyNative = key.toNativeUtf16();
    final valueNative = value.toNativeUtf16();
    try {
      final setEnvironmentVariable = ffi.DynamicLibrary.open('kernel32.dll')
          .lookupFunction<
            ffi.Int32 Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>),
            int Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>)
          >('SetEnvironmentVariableW');
      setEnvironmentVariable(keyNative, valueNative);
    } finally {
      calloc.free(keyNative);
      calloc.free(valueNative);
    }
  } else if (Platform.isMacOS || Platform.isLinux) {
    final keyNative = key.toNativeUtf8();
    final valueNative = value.toNativeUtf8();
    try {
      final setenv = ffi.DynamicLibrary.process()
          .lookupFunction<
            ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Int32),
            int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, int)
          >('setenv');
      setenv(keyNative, valueNative, 1);
    } finally {
      calloc.free(keyNative);
      calloc.free(valueNative);
    }
  }
}
