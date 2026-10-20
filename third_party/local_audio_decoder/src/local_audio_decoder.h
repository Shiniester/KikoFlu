#ifndef KIKO_AUDIO_DECODER_H_
#define KIKO_AUDIO_DECODER_H_

#include <stdint.h>

#if defined(_WIN32)
#define KIKO_AUDIO_DECODER_EXPORT __declspec(dllexport)
#else
#define KIKO_AUDIO_DECODER_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define KIKO_AUDIO_DECODER_MAX_READ_FRAMES 1048576U

KIKO_AUDIO_DECODER_EXPORT int32_t kiko_audio_decoder_open(
    const char *path_utf8,
    uint32_t sample_rate,
    void **out_decoder,
    char *error_message,
    uint32_t error_capacity);
KIKO_AUDIO_DECODER_EXPORT int32_t kiko_audio_decoder_read(
    void *decoder,
    float *output,
    uint64_t max_frames,
    uint64_t *out_frames,
    char *error_message,
    uint32_t error_capacity);
KIKO_AUDIO_DECODER_EXPORT int64_t kiko_audio_decoder_total_frames(void *decoder);
KIKO_AUDIO_DECODER_EXPORT uint32_t kiko_audio_decoder_sample_rate(void *decoder);
KIKO_AUDIO_DECODER_EXPORT void kiko_audio_decoder_close(void *decoder);

#ifdef __cplusplus
}
#endif

#endif
