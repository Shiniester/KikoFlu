# local_audio_decoder

Import `package:local_audio_decoder/local_audio_decoder.dart` and open a file with `LocalAudioDecoder.open(path, sampleRate: 16000)`. Each `read(maxFrames)` returns a copied `Float32List` with the frames actually decoded; an empty list means EOF. The maximum read is 1,048,576 frames, and the decoder does not retain the complete decoded audio in memory. Call `close` when finished.

MP3 length lookup scans the file when opening because miniaudio must decode it to determine the output frame count. The scan does not retain the PCM data.

The bundled miniaudio version and license are recorded in [THIRD_PARTY.md](THIRD_PARTY.md).
