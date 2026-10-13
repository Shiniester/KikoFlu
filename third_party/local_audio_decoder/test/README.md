# Native smoke check

Run `native_smoke.c` from the package directory after compiling it with `src/local_audio_decoder.c`. It opens a short WAV through a Japanese Windows path, reads it in 1,024-frame chunks to EOF, and checks that an unsupported file fails with an error.

The WAV fixture is 4,000 mono PCM frames at 16 kHz. `not-audio.m4a` is deliberately invalid input.

On Windows, run from a Visual Studio x64 developer prompt:

```bat
if not exist "%TEMP%\local_audio_decoder_smoke" mkdir "%TEMP%\local_audio_decoder_smoke"
cl /nologo /TC /utf-8 /D_CRT_SECURE_NO_WARNINGS /Fo:"%TEMP%\local_audio_decoder_smoke\" /Fe:"%TEMP%\local_audio_decoder_smoke\smoke.exe" test\native_smoke.c src\local_audio_decoder.c
"%TEMP%\local_audio_decoder_smoke\smoke.exe"
```

On Linux, run:

```sh
cc -std=c99 test/native_smoke.c src/local_audio_decoder.c -lm -o /tmp/local_audio_decoder_smoke
/tmp/local_audio_decoder_smoke
```
