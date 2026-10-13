#include "local_audio_decoder.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

#define MA_NO_DEVICE_IO
#define MA_NO_THREADING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

typedef struct {
  ma_decoder decoder;
  ma_uint64 total_frames;
  ma_uint32 sample_rate;
} kiko_audio_decoder;

enum {
  KIKO_AUDIO_DECODER_OK = 0,
  KIKO_AUDIO_DECODER_INVALID_ARGUMENT = 1,
  KIKO_AUDIO_DECODER_OPEN_FAILED = 2,
  KIKO_AUDIO_DECODER_READ_FAILED = 3,
  KIKO_AUDIO_DECODER_OUT_OF_MEMORY = 4,
};

static void set_error(char *error_message, uint32_t error_capacity, const char *message) {
  if (error_message == NULL || error_capacity == 0) {
    return;
  }

  snprintf(error_message, error_capacity, "%s", message);
}

static void set_result_error(
    char *error_message,
    uint32_t error_capacity,
    const char *operation,
    ma_result result) {
  if (error_message == NULL || error_capacity == 0) {
    return;
  }

  snprintf(error_message, error_capacity, "%s: %s", operation, ma_result_description(result));
}

static ma_result decoder_init_path(const char *path_utf8, const ma_decoder_config *config, ma_decoder *decoder) {
#if defined(_WIN32)
  int wide_length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path_utf8, -1, NULL, 0);
  if (wide_length == 0) {
    return MA_INVALID_ARGS;
  }

  wchar_t *wide_path = (wchar_t *)malloc((size_t)wide_length * sizeof(wchar_t));
  if (wide_path == NULL) {
    return MA_OUT_OF_MEMORY;
  }

  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path_utf8, -1, wide_path, wide_length) == 0) {
    free(wide_path);
    return MA_INVALID_ARGS;
  }

  ma_result result = ma_decoder_init_file_w(wide_path, config, decoder);
  free(wide_path);
  return result;
#else
  return ma_decoder_init_file(path_utf8, config, decoder);
#endif
}

int32_t kiko_audio_decoder_open(
    const char *path_utf8,
    uint32_t sample_rate,
    void **out_decoder,
    char *error_message,
    uint32_t error_capacity) {
  if (out_decoder != NULL) {
    *out_decoder = NULL;
  }
  set_error(error_message, error_capacity, "");

  if (path_utf8 == NULL || path_utf8[0] == '\0' || sample_rate == 0 || out_decoder == NULL) {
    set_error(error_message, error_capacity, "path, sample rate, and output handle are required");
    return KIKO_AUDIO_DECODER_INVALID_ARGUMENT;
  }

  kiko_audio_decoder *decoder = (kiko_audio_decoder *)calloc(1, sizeof(kiko_audio_decoder));
  if (decoder == NULL) {
    set_error(error_message, error_capacity, "could not allocate decoder");
    return KIKO_AUDIO_DECODER_OUT_OF_MEMORY;
  }

  ma_decoder_config config = ma_decoder_config_init(ma_format_f32, 1, sample_rate);
  ma_result result = decoder_init_path(path_utf8, &config, &decoder->decoder);
  if (result != MA_SUCCESS) {
    set_result_error(error_message, error_capacity, "could not open audio", result);
    free(decoder);
    return KIKO_AUDIO_DECODER_OPEN_FAILED;
  }

  result = ma_decoder_get_length_in_pcm_frames(&decoder->decoder, &decoder->total_frames);
  if (result != MA_SUCCESS || decoder->total_frames == 0 || decoder->total_frames > INT64_MAX) {
    if (result == MA_SUCCESS) {
      set_error(error_message, error_capacity, "audio length is unavailable or out of range");
    } else {
      set_result_error(error_message, error_capacity, "could not determine audio length", result);
    }
    ma_decoder_uninit(&decoder->decoder);
    free(decoder);
    return KIKO_AUDIO_DECODER_OPEN_FAILED;
  }

  result = ma_decoder_seek_to_pcm_frame(&decoder->decoder, 0);
  if (result != MA_SUCCESS) {
    set_result_error(error_message, error_capacity, "could not rewind audio", result);
    ma_decoder_uninit(&decoder->decoder);
    free(decoder);
    return KIKO_AUDIO_DECODER_OPEN_FAILED;
  }

  decoder->sample_rate = sample_rate;
  *out_decoder = decoder;
  return KIKO_AUDIO_DECODER_OK;
}

int32_t kiko_audio_decoder_read(
    void *decoder_handle,
    float *output,
    uint64_t max_frames,
    uint64_t *out_frames,
    char *error_message,
    uint32_t error_capacity) {
  set_error(error_message, error_capacity, "");
  if (out_frames != NULL) {
    *out_frames = 0;
  }

  if (decoder_handle == NULL || out_frames == NULL ||
      (max_frames > 0 && output == NULL) ||
      max_frames > KIKO_AUDIO_DECODER_MAX_READ_FRAMES) {
    set_error(error_message, error_capacity, "decoder, output buffer, or frame count is invalid");
    return KIKO_AUDIO_DECODER_INVALID_ARGUMENT;
  }
  if (max_frames == 0) {
    return KIKO_AUDIO_DECODER_OK;
  }

  kiko_audio_decoder *decoder = (kiko_audio_decoder *)decoder_handle;
  ma_uint64 frames_read = 0;
  ma_result result = ma_decoder_read_pcm_frames(&decoder->decoder, output, max_frames, &frames_read);
  if (result != MA_SUCCESS && result != MA_AT_END) {
    set_result_error(error_message, error_capacity, "could not decode audio", result);
    return KIKO_AUDIO_DECODER_READ_FAILED;
  }

  *out_frames = frames_read;
  return KIKO_AUDIO_DECODER_OK;
}

int64_t kiko_audio_decoder_total_frames(void *decoder_handle) {
  if (decoder_handle == NULL) {
    return 0;
  }
  const kiko_audio_decoder *decoder = (const kiko_audio_decoder *)decoder_handle;
  return (int64_t)decoder->total_frames;
}

uint32_t kiko_audio_decoder_sample_rate(void *decoder_handle) {
  if (decoder_handle == NULL) {
    return 0;
  }
  const kiko_audio_decoder *decoder = (const kiko_audio_decoder *)decoder_handle;
  return decoder->sample_rate;
}

void kiko_audio_decoder_close(void *decoder_handle) {
  if (decoder_handle == NULL) {
    return;
  }
  kiko_audio_decoder *decoder = (kiko_audio_decoder *)decoder_handle;
  ma_decoder_uninit(&decoder->decoder);
  free(decoder);
}
