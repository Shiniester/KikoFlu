#include "../src/local_audio_decoder.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#if defined(_WIN32)
#include <windows.h>

static char *wide_to_utf8(const wchar_t *path) {
  int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, -1, NULL, 0, NULL, NULL);
  if (length == 0) {
    return NULL;
  }
  char *utf8_path = (char *)malloc((size_t)length);
  if (utf8_path == NULL ||
      WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, -1, utf8_path, length, NULL, NULL) == 0) {
    free(utf8_path);
    return NULL;
  }
  return utf8_path;
}
#endif

static int run_smoke(const char *valid_path) {
  char error[512] = {0};
  void *decoder = NULL;
  int32_t status = kiko_audio_decoder_open(valid_path, 16000, &decoder, error, sizeof(error));
  if (status != 0 || decoder == NULL) {
    fprintf(stderr, "WAV open failed: %s\n", error);
    return 1;
  }

  int64_t expected_frames = kiko_audio_decoder_total_frames(decoder);
  if (kiko_audio_decoder_sample_rate(decoder) != 16000 || expected_frames != 4000) {
    fprintf(stderr, "unexpected format: sampleRate=%u totalFrames=%lld\n",
            kiko_audio_decoder_sample_rate(decoder), (long long)expected_frames);
    kiko_audio_decoder_close(decoder);
    return 1;
  }

  float buffer[1024];
  uint64_t total_frames = 0;
  float peak = 0.0f;
  for (;;) {
    uint64_t frames_read = 0;
    status = kiko_audio_decoder_read(decoder, buffer, 1024, &frames_read, error, sizeof(error));
    if (status != 0) {
      fprintf(stderr, "WAV read failed: %s\n", error);
      kiko_audio_decoder_close(decoder);
      return 1;
    }
    if (frames_read == 0) {
      break;
    }
    total_frames += frames_read;
    for (uint64_t i = 0; i < frames_read; ++i) {
      if (!isfinite(buffer[i])) {
        fprintf(stderr, "decoder returned a non-finite sample\n");
        kiko_audio_decoder_close(decoder);
        return 1;
      }
      if (fabsf(buffer[i]) > peak) {
        peak = fabsf(buffer[i]);
      }
    }
  }
  kiko_audio_decoder_close(decoder);

  if (total_frames != (uint64_t)expected_frames || peak < 0.25f) {
    fprintf(stderr, "unexpected decode: frames=%llu peak=%f\n",
            (unsigned long long)total_frames, peak);
    return 1;
  }

  void *bad_decoder = NULL;
#if defined(_WIN32)
  status = kiko_audio_decoder_open("test\\fixtures\\not-audio.m4a", 16000, &bad_decoder, error, sizeof(error));
#else
  status = kiko_audio_decoder_open("test/fixtures/not-audio.m4a", 16000, &bad_decoder, error, sizeof(error));
#endif
  if (status == 0 || bad_decoder != NULL || error[0] == '\0') {
    fprintf(stderr, "unsupported/bad input did not fail\n");
    kiko_audio_decoder_close(bad_decoder);
    return 1;
  }

  puts("native audio decoder smoke passed");
  return 0;
}

#if defined(_WIN32)
int wmain(void) {
  char *valid_path = wide_to_utf8(L"test\\fixtures\\\u65e5\u672c\u8a9e\u97f3\u58f0.wav");
  if (valid_path == NULL) {
    fputs("could not encode Unicode fixture path as UTF-8\n", stderr);
    return 1;
  }
  int result = run_smoke(valid_path);
  free(valid_path);
  return result;
}
#else
int main(void) {
  return run_smoke("test/fixtures/\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\xe9\x9f\xb3\xe5\xa3\xb0.wav");
}
#endif
