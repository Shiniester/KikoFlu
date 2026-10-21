import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../utils/audio_source_headers.dart';
import 'remote_asset_cache.dart';

typedef JapaneseAsmrChapterProgress =
    void Function(int downloadedBytes, int? totalBytes);

class JapaneseAsmrChapterDownloader {
  JapaneseAsmrChapterDownloader({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.connectTimeout ??= const Duration(seconds: 20);
    _dio.options.receiveTimeout ??= const Duration(seconds: 25);
  }

  static const int _ptsModulus = 1 << 33;
  static const int _ptsHalfRange = _ptsModulus >> 1;
  static const Map<int, int> _sampleRates = {
    0: 96000,
    1: 88200,
    2: 64000,
    3: 48000,
    4: 44100,
    5: 32000,
    6: 24000,
    7: 22050,
    8: 16000,
    9: 12000,
    10: 11025,
    11: 8000,
    12: 7350,
  };

  final Dio _dio;

  Future<int> download({
    required String playlistUrl,
    required int startTimeMs,
    required int? endTimeMs,
    required File outputFile,
    required RemoteAssetCancellation cancellation,
    JapaneseAsmrChapterProgress? onProgress,
  }) async {
    if (startTimeMs < 0 || (endTimeMs != null && endTimeMs <= startTimeMs)) {
      throw ArgumentError('Invalid Japanese ASMR chapter interval');
    }

    final cancelToken = CancelToken();
    if (cancellation.isCancelled) cancelToken.cancel('Download cancelled');
    unawaited(
      cancellation.whenCancelled.then((_) {
        if (!cancelToken.isCancelled) cancelToken.cancel('Download cancelled');
      }),
    );

    var outputComplete = false;
    RandomAccessFile? output;
    try {
      _checkCancelled(cancellation);
      final playlistResponse = await _dio.get<List<int>>(
        playlistUrl,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.bytes,
          headers: japaneseAsmrRequestHeaders,
        ),
      );
      final playlistBytes = playlistResponse.data;
      if (playlistBytes == null || _looksLikeHtml(playlistBytes)) {
        throw const HttpException('Japanese ASMR playlist returned HTML');
      }
      final playlist = _parsePlaylist(
        utf8.decode(playlistBytes),
        playlistResponse.realUri,
      );
      final selectedSegments = playlist.segments
          .where((segment) {
            final chapterStartUs = startTimeMs * 1000;
            final chapterEndUs = endTimeMs == null
                ? playlist.durationUs
                : endTimeMs * 1000;
            return segment.startUs < chapterEndUs &&
                segment.startUs + segment.durationUs > chapterStartUs;
          })
          .toList(growable: false);
      if (selectedSegments.isEmpty) {
        throw const FormatException(
          'Chapter interval is outside the Japanese ASMR playlist',
        );
      }

      final playlistEndUs = playlist.durationUs;
      final requestedEndUs = endTimeMs == null
          ? playlistEndUs
          : (endTimeMs * 1000).clamp(0, playlistEndUs).toInt();
      final chapterStartTicks = _timeUsToPts(startTimeMs * 1000);
      final chapterEndTicks = _timeUsToPts(requestedEndUs);
      final chapterDurationTicks = chapterEndTicks > chapterStartTicks
          ? chapterEndTicks - chapterStartTicks
          : 0;
      await outputFile.parent.create(recursive: true);
      output = await outputFile.open(mode: FileMode.write);

      int? firstFramePts;
      int? phaseTicks;
      var writtenDurationTicks = 0;
      var writtenBytes = 0;

      for (final segment in selectedSegments) {
        _checkCancelled(cancellation);
        final segmentResponse = await _dio.get<List<int>>(
          segment.uri.toString(),
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.bytes,
            headers: japaneseAsmrRequestHeaders,
          ),
        );
        final segmentBytes = segmentResponse.data;
        if (segmentBytes == null || _looksLikeHtml(segmentBytes)) {
          throw const HttpException('Japanese ASMR segment returned HTML');
        }
        final frames = _decodeTransportStream(segmentBytes, cancellation);
        if (frames.isEmpty) {
          throw const FormatException(
            'Japanese ASMR segment has no AAC frames',
          );
        }

        final segmentFirstPts = frames.first.ptsTicks;
        firstFramePts ??= segmentFirstPts;
        phaseTicks ??=
            firstFramePts - _timeUsToPts(selectedSegments.first.startUs);
        final expectedFirstPts =
            firstFramePts +
            _timeUsToPts(segment.startUs - selectedSegments.first.startUs);
        final alignedSegmentFirstPts = _unwrapNear(
          segmentFirstPts,
          expectedFirstPts,
        );
        final outputSegment = BytesBuilder(copy: false);
        var segmentDurationTicks = 0;
        for (var index = 0; index < frames.length; index++) {
          if (index % 256 == 0) _checkCancelled(cancellation);
          final frame = frames[index];
          final alignedPts =
              alignedSegmentFirstPts + frame.ptsTicks - segmentFirstPts;
          final chapterTimeTicks = alignedPts - phaseTicks;
          if (chapterTimeTicks >= chapterStartTicks &&
              chapterTimeTicks < chapterEndTicks) {
            outputSegment.add(frame.bytes);
            segmentDurationTicks += frame.durationTicks;
          }
        }
        final segmentOutputBytes = outputSegment.takeBytes();
        if (segmentOutputBytes.isNotEmpty) {
          await output.writeFrom(segmentOutputBytes);
          writtenBytes += segmentOutputBytes.length;
          writtenDurationTicks += segmentDurationTicks;
        }
        await output.flush();
        if (chapterDurationTicks > 0 && writtenDurationTicks > 0) {
          final estimate =
              (writtenBytes * chapterDurationTicks / writtenDurationTicks)
                  .ceil();
          onProgress?.call(
            writtenBytes,
            estimate > writtenBytes ? estimate : writtenBytes,
          );
        } else {
          onProgress?.call(writtenBytes, null);
        }
      }

      if (writtenBytes == 0) {
        throw const FormatException('Chapter interval contains no AAC frames');
      }
      await output.flush();
      await output.close();
      output = null;
      onProgress?.call(writtenBytes, writtenBytes);
      outputComplete = true;
      return writtenBytes;
    } on DioException catch (error) {
      if (cancellation.isCancelled || CancelToken.isCancel(error)) {
        throw const HttpException('Japanese ASMR chapter download cancelled');
      }
      rethrow;
    } finally {
      await output?.close();
      if (!outputComplete && await outputFile.exists()) {
        await outputFile.delete();
      }
    }
  }

  _HlsPlaylist _parsePlaylist(String source, Uri playlistUri) {
    final segments = <_HlsSegment>[];
    var pendingDurationUs = 0;
    var timelineUs = 0;
    var sawEndList = false;
    for (final rawLine in const LineSplitter().convert(source)) {
      final line = rawLine.trim();
      if (line.isEmpty || line == '#EXTM3U') continue;
      if (line.startsWith('#EXTINF:')) {
        final value = line.substring('#EXTINF:'.length).split(',').first;
        final duration = double.tryParse(value);
        if (duration == null || !duration.isFinite || duration <= 0) {
          throw const FormatException('Invalid HLS segment duration');
        }
        pendingDurationUs = (duration * 1000000).round();
        continue;
      }
      if (line == '#EXT-X-ENDLIST') {
        sawEndList = true;
        continue;
      }
      if (line.startsWith('#')) {
        const supportedTags = {
          '#EXT-X-VERSION:',
          '#EXT-X-TARGETDURATION:',
          '#EXT-X-MEDIA-SEQUENCE:',
          '#EXT-X-PLAYLIST-TYPE:',
        };
        if (line.startsWith('#EXT-X-') && !supportedTags.any(line.startsWith)) {
          throw FormatException('Unsupported HLS playlist tag: $line');
        }
        continue;
      }
      if (pendingDurationUs <= 0) {
        throw const FormatException('HLS segment is missing EXTINF');
      }
      segments.add(
        _HlsSegment(
          uri: playlistUri.resolve(line),
          startUs: timelineUs,
          durationUs: pendingDurationUs,
        ),
      );
      timelineUs += pendingDurationUs;
      pendingDurationUs = 0;
    }
    if (!sawEndList || segments.isEmpty || pendingDurationUs != 0) {
      throw const FormatException('Expected a complete HLS VOD playlist');
    }
    return _HlsPlaylist(segments: segments, durationUs: timelineUs);
  }

  List<_AacFrame> _decodeTransportStream(
    List<int> data,
    RemoteAssetCancellation cancellation,
  ) {
    if (data.isEmpty || data.length % 188 != 0) {
      throw const FormatException('Invalid MPEG-TS segment length');
    }
    final packets = <_TsPacket>[];
    for (var offset = 0; offset < data.length; offset += 188) {
      if (offset % (188 * 1024) == 0) _checkCancelled(cancellation);
      if (data[offset] != 0x47) {
        throw const FormatException('Invalid MPEG-TS sync byte');
      }
      final byte1 = data[offset + 1];
      final byte3 = data[offset + 3];
      if ((byte1 & 0x80) != 0 || (byte3 & 0xc0) != 0) {
        throw const FormatException('Invalid or scrambled MPEG-TS packet');
      }
      final adaptationControl = (byte3 >> 4) & 0x03;
      if (adaptationControl == 0) {
        throw const FormatException('Invalid MPEG-TS adaptation control');
      }
      var payloadOffset = offset + 4;
      var discontinuity = false;
      if ((adaptationControl & 0x02) != 0) {
        final adaptationLength = data[payloadOffset];
        if (adaptationLength > 0) {
          discontinuity = (data[payloadOffset + 1] & 0x80) != 0;
        }
        payloadOffset += 1 + adaptationLength;
        if (payloadOffset > offset + 188) {
          throw const FormatException('Invalid MPEG-TS adaptation field');
        }
      }
      if ((adaptationControl & 0x01) == 0 || payloadOffset >= offset + 188) {
        continue;
      }
      final pid = ((byte1 & 0x1f) << 8) | data[offset + 2];
      packets.add(
        _TsPacket(
          pid: pid,
          payloadUnitStart: (byte1 & 0x40) != 0,
          continuityCounter: byte3 & 0x0f,
          discontinuity: discontinuity,
          payload: data.sublist(payloadOffset, offset + 188),
        ),
      );
    }

    final pat = _readPsiSection(packets, 0, 0x00);
    var pmtPid = -1;
    for (var offset = 8; offset + 4 <= pat.length - 4; offset += 4) {
      final program = (pat[offset] << 8) | pat[offset + 1];
      if (program != 0) {
        pmtPid = ((pat[offset + 2] & 0x1f) << 8) | pat[offset + 3];
        break;
      }
    }
    if (pmtPid < 0) {
      throw const FormatException('MPEG-TS contains no program');
    }
    final pmt = _readPsiSection(packets, pmtPid, 0x02);
    final programInfoLength = ((pmt[10] & 0x0f) << 8) | pmt[11];
    var offset = 12 + programInfoLength;
    var audioPid = -1;
    var audioCodec = -1;
    while (offset + 5 <= pmt.length - 4) {
      final streamType = pmt[offset];
      final pid = ((pmt[offset + 1] & 0x1f) << 8) | pmt[offset + 2];
      final infoLength = ((pmt[offset + 3] & 0x0f) << 8) | pmt[offset + 4];
      if (streamType == 0x0f) {
        audioPid = pid;
        audioCodec = streamType;
        break;
      }
      if (audioCodec < 0 &&
          const {0x03, 0x04, 0x11, 0x1b, 0x24}.contains(streamType)) {
        audioCodec = streamType;
      }
      offset += 5 + infoLength;
    }
    if (audioPid < 0) {
      throw FormatException(
        audioCodec < 0
            ? 'MPEG-TS contains no supported audio stream'
            : 'Unsupported MPEG-TS audio codec: 0x${audioCodec.toRadixString(16)}',
      );
    }

    final frames = <_AacFrame>[];
    final pesBytes = BytesBuilder(copy: false);
    var hasPes = false;
    var previousContinuityCounter = -1;
    void finishPes() {
      if (!hasPes) return;
      frames.addAll(_decodePes(pesBytes.takeBytes()));
      hasPes = false;
    }

    for (final packet in packets) {
      if (packet.pid != audioPid) continue;
      if (packet.discontinuity) {
        throw const FormatException(
          'MPEG-TS audio discontinuity is unsupported',
        );
      }
      if (previousContinuityCounter >= 0 &&
          packet.continuityCounter != (previousContinuityCounter + 1) % 16) {
        throw const FormatException('MPEG-TS audio packet is discontinuous');
      }
      previousContinuityCounter = packet.continuityCounter;
      if (packet.payloadUnitStart) {
        finishPes();
        hasPes = true;
      }
      if (hasPes) pesBytes.add(packet.payload);
    }
    finishPes();
    return frames;
  }

  Uint8List _readPsiSection(List<_TsPacket> packets, int pid, int tableId) {
    for (final packet in packets) {
      if (packet.pid != pid || !packet.payloadUnitStart) continue;
      final pointer = packet.payload.first;
      final start = pointer + 1;
      if (start > packet.payload.length) {
        throw const FormatException('Invalid MPEG-TS table pointer');
      }
      if (start + 3 > packet.payload.length ||
          packet.payload[start] != tableId) {
        continue;
      }
      final sectionLength =
          ((packet.payload[start + 1] & 0x0f) << 8) | packet.payload[start + 2];
      final length = 3 + sectionLength;
      if (length < 8 || start + length > packet.payload.length) {
        throw const FormatException('Incomplete MPEG-TS program table');
      }
      return Uint8List.fromList(packet.payload.sublist(start, start + length));
    }
    throw const FormatException('MPEG-TS program table is missing');
  }

  List<_AacFrame> _decodePes(List<int> source) {
    if (source.length < 9 ||
        source[0] != 0 ||
        source[1] != 0 ||
        source[2] != 1 ||
        (source[3] & 0xf0) != 0xc0) {
      throw const FormatException('Invalid MPEG audio PES packet');
    }
    final packetLength = (source[4] << 8) | source[5];
    final packetEnd = packetLength == 0 ? source.length : 6 + packetLength;
    if (packetEnd > source.length) {
      throw const FormatException('Truncated MPEG audio PES packet');
    }
    final flags = source[7];
    final headerLength = source[8];
    final audioOffset = 9 + headerLength;
    if ((flags & 0x80) == 0 || headerLength < 5 || audioOffset > packetEnd) {
      throw const FormatException('MPEG audio PES packet has no PTS');
    }
    final pts = _parsePts(source, 9);
    var sampleOffset = 0;
    var offset = audioOffset;
    final frames = <_AacFrame>[];
    while (offset < packetEnd) {
      if (offset + 7 > packetEnd ||
          source[offset] != 0xff ||
          (source[offset + 1] & 0xf6) != 0xf0) {
        throw const FormatException('MPEG audio PES payload is not ADTS AAC');
      }
      final sampleRateIndex = (source[offset + 2] >> 2) & 0x0f;
      final sampleRate = _sampleRates[sampleRateIndex];
      if (sampleRate == null) {
        throw const FormatException('Invalid ADTS AAC sample rate');
      }
      final frameLength =
          ((source[offset + 3] & 0x03) << 11) |
          (source[offset + 4] << 3) |
          (source[offset + 5] >> 5);
      final headerLength = (source[offset + 1] & 1) == 1 ? 7 : 9;
      if (frameLength < headerLength || offset + frameLength > packetEnd) {
        throw const FormatException('Truncated ADTS AAC frame');
      }
      final rawDataBlocks = source[offset + 6] & 0x03;
      final samples = 1024 * (rawDataBlocks + 1);
      final ptsTicks = pts + (sampleOffset * 90000 / sampleRate).round();
      frames.add(
        _AacFrame(
          ptsTicks: ptsTicks,
          durationTicks: (samples * 90000 / sampleRate).round(),
          bytes: Uint8List.fromList(
            source.sublist(offset, offset + frameLength),
          ),
        ),
      );
      sampleOffset += samples;
      offset += frameLength;
    }
    if (frames.isEmpty) {
      throw const FormatException(
        'MPEG audio PES packet contains no AAC frames',
      );
    }
    return frames;
  }

  int _parsePts(List<int> data, int offset) {
    final first = data[offset];
    final fourth = data[offset + 3];
    final fifth = data[offset + 4];
    if ((first & 1) != 1 || (data[offset + 2] & 1) != 1 || (fifth & 1) != 1) {
      throw const FormatException('Invalid MPEG audio PTS');
    }
    return (((first >> 1) & 0x07) << 30) |
        (data[offset + 1] << 22) |
        (((data[offset + 2] >> 1) & 0x7f) << 15) |
        (fourth << 7) |
        ((fifth >> 1) & 0x7f);
  }

  int _unwrapNear(int pts, int expected) {
    var candidate = (expected ~/ _ptsModulus) * _ptsModulus + pts;
    if (candidate - expected > _ptsHalfRange) candidate -= _ptsModulus;
    if (expected - candidate > _ptsHalfRange) candidate += _ptsModulus;
    return candidate;
  }

  int _timeUsToPts(int microseconds) =>
      (microseconds * 90000 / 1000000).round();

  bool _looksLikeHtml(List<int> bytes) {
    final prefix = utf8
        .decode(bytes.take(128).toList(growable: false), allowMalformed: true)
        .trimLeft()
        .toLowerCase();
    return prefix.startsWith('<!doctype html') ||
        prefix.startsWith('<html') ||
        prefix.startsWith('<head') ||
        prefix.startsWith('<body');
  }

  void _checkCancelled(RemoteAssetCancellation cancellation) {
    if (cancellation.isCancelled) {
      throw const HttpException('Japanese ASMR chapter download cancelled');
    }
  }
}

class _HlsPlaylist {
  const _HlsPlaylist({required this.segments, required this.durationUs});

  final List<_HlsSegment> segments;
  final int durationUs;
}

class _HlsSegment {
  const _HlsSegment({
    required this.uri,
    required this.startUs,
    required this.durationUs,
  });

  final Uri uri;
  final int startUs;
  final int durationUs;
}

class _TsPacket {
  const _TsPacket({
    required this.pid,
    required this.payloadUnitStart,
    required this.continuityCounter,
    required this.discontinuity,
    required this.payload,
  });

  final int pid;
  final bool payloadUnitStart;
  final int continuityCounter;
  final bool discontinuity;
  final List<int> payload;
}

class _AacFrame {
  const _AacFrame({
    required this.ptsTicks,
    required this.durationTicks,
    required this.bytes,
  });

  final int ptsTicks;
  final int durationTicks;
  final Uint8List bytes;
}
