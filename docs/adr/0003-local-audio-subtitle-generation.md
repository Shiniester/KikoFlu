# ADR 0003: Generate audio subtitles on the user's device

## Status

Accepted

## Decision

Audio Subtitle Generation runs on the user's device. Audio is never uploaded to
a transcription service; subtitle text may use the existing online translation
services through a separate manual action. Recognition models are downloaded on
demand and reused locally.

The first version uses the official sherpa_onnx Flutter binding with the Japanese
ReazonSpeech model and a shared miniaudio decoder bridge for MP3, WAV and FLAC.
The binding provides a Linux ARM64 library selection path. This combination
preserves the existing iOS 13 baseline and Linux ARM64 release target. The
trade-off is maintaining one shared decoder C ABI and its
build integration for the existing platform architectures.

The product scope, task lifecycle and acceptance checks are defined in
[Local audio subtitle generation](../development/local-audio-subtitles.md).

## Evidence

- [Sherpa Linux library selection](https://github.com/k2-fsa/sherpa-onnx/blob/master/flutter/sherpa_onnx_linux/linux/CMakeLists.txt)
- [ReazonSpeech models](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/zipformer-transducer-models.html)
- [miniaudio decoder support](https://github.com/mackron/miniaudio)
