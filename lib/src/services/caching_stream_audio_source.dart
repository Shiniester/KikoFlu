// ignore_for_file: experimental_member_use
import 'package:just_audio/just_audio.dart';

import 'audio_stream_cache.dart';

class CachingStreamAudioSource extends StreamAudioSource {
  CachingStreamAudioSource({required this.cache, required this.transfer});

  final AudioStreamCache cache;
  final AudioTransferRequest transfer;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    return cache.openRange(transfer, start, end);
  }
}
