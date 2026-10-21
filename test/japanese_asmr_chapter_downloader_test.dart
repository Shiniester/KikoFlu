import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/japanese_asmr_chapter_downloader.dart';
import 'package:kikoeru_flutter/src/services/remote_asset_cache.dart';

void main() {
  late Directory tempDirectory;
  late Dio dio;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'japanese_asmr_chapter_test_',
    );
  });

  tearDown(() async {
    dio.close(force: true);
    await tempDirectory.delete(recursive: true);
  });

  test(
    'writes AAC frames inside the chapter range from selected segments',
    () async {
      final requests = <RequestOptions>[];
      final segments = [
        _transportSegment(126000, frameMarkerBase: 0),
        _transportSegment(216000, frameMarkerBase: 46),
        _transportSegment(306000, frameMarkerBase: 92),
      ];
      dio = _dioFor(requests, segments: segments);
      final output = File('${tempDirectory.path}/chapter.aac');

      final bytes = await JapaneseAsmrChapterDownloader(dio: dio).download(
        playlistUrl: 'https://media.example/work.m3u8',
        startTimeMs: 500,
        endTimeMs: 1500,
        outputFile: output,
        cancellation: RemoteAssetCancellation(),
      );

      expect(bytes, 46 * 11);
      expect(await output.length(), 46 * 11);
      expect(
        await output.readAsBytes(),
        Uint8List.fromList([
          for (var index = 24; index < 46; index++) ..._adtsFrame(index),
          for (var index = 46; index < 70; index++) ..._adtsFrame(index),
        ]),
      );
      expect(requests.map((request) => request.uri.path), [
        '/work.m3u8',
        '/segment-0.ts',
        '/segment-1.ts',
      ]);
      expect(
        requests.every(
          (request) =>
              request.headers['Referer'] == 'https://japaneseasmr.com/',
        ),
        isTrue,
      );
      expect(
        requests.every(
          (request) => !request.headers.keys.any(
            (name) => name.toLowerCase() == 'cookie',
          ),
        ),
        isTrue,
      );
    },
  );

  test(
    'uses the playlist end for a final chapter without an end time',
    () async {
      final requests = <RequestOptions>[];
      dio = _dioFor(
        requests,
        segments: [
          _transportSegment(126000, frameMarkerBase: 0),
          _transportSegment(216000, frameMarkerBase: 46),
          _transportSegment(306000, frameMarkerBase: 92),
        ],
      );
      final output = File('${tempDirectory.path}/final.aac');

      final bytes = await JapaneseAsmrChapterDownloader(dio: dio).download(
        playlistUrl: 'https://media.example/work.m3u8',
        startTimeMs: 2000,
        endTimeMs: null,
        outputFile: output,
        cancellation: RemoteAssetCancellation(),
      );

      expect(bytes, 46 * 11);
      expect(
        await output.readAsBytes(),
        Uint8List.fromList([
          for (var index = 92; index < 138; index++) ..._adtsFrame(index),
        ]),
      );
      expect(requests.map((request) => request.uri.path), [
        '/work.m3u8',
        '/segment-2.ts',
      ]);
    },
  );

  test(
    'rejects HTML and unsupported transport audio without leaving a file',
    () async {
      final htmlRequests = <RequestOptions>[];
      dio = Dio()
        ..httpClientAdapter = _Adapter((request) {
          htmlRequests.add(request);
          return ResponseBody.fromString(
            '<html>blocked</html>',
            HttpStatus.ok,
            headers: {
              Headers.contentTypeHeader: ['text/html'],
            },
          );
        });
      final htmlOutput = File('${tempDirectory.path}/html.aac');
      await expectLater(
        JapaneseAsmrChapterDownloader(dio: dio).download(
          playlistUrl: 'https://media.example/work.m3u8',
          startTimeMs: 0,
          endTimeMs: null,
          outputFile: htmlOutput,
          cancellation: RemoteAssetCancellation(),
        ),
        throwsA(isA<HttpException>()),
      );
      expect(await htmlOutput.exists(), isFalse);

      final codecRequests = <RequestOptions>[];
      dio.close(force: true);
      dio = _dioFor(
        codecRequests,
        segments: [_transportSegment(126000, streamType: 0x03)],
        segmentCount: 1,
      );
      final codecOutput = File('${tempDirectory.path}/codec.aac');
      await expectLater(
        JapaneseAsmrChapterDownloader(dio: dio).download(
          playlistUrl: 'https://media.example/work.m3u8',
          startTimeMs: 0,
          endTimeMs: null,
          outputFile: codecOutput,
          cancellation: RemoteAssetCancellation(),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await codecOutput.exists(), isFalse);
    },
  );

  test('cancellation removes the partial chapter file', () async {
    final cancellation = RemoteAssetCancellation();
    final requests = <RequestOptions>[];
    dio = _dioFor(
      requests,
      segments: [_transportSegment(126000)],
      segmentCount: 1,
      onSegment: cancellation.cancel,
    );
    final output = File('${tempDirectory.path}/cancelled.aac');

    await expectLater(
      JapaneseAsmrChapterDownloader(dio: dio).download(
        playlistUrl: 'https://media.example/work.m3u8',
        startTimeMs: 0,
        endTimeMs: null,
        outputFile: output,
        cancellation: cancellation,
      ),
      throwsA(isA<HttpException>()),
    );
    expect(await output.exists(), isFalse);
  });
}

Dio _dioFor(
  List<RequestOptions> requests, {
  required List<Uint8List> segments,
  int? segmentCount,
  void Function()? onSegment,
}) {
  final count = segmentCount ?? segments.length;
  final playlist = [
    '#EXTM3U',
    '#EXT-X-VERSION:3',
    '#EXT-X-PLAYLIST-TYPE:VOD',
    for (var index = 0; index < count; index++) ...[
      '#EXTINF:1.000,',
      'segment-$index.ts',
    ],
    '#EXT-X-ENDLIST',
  ].join('\n');
  return Dio()
    ..httpClientAdapter = _Adapter((request) {
      requests.add(request);
      if (request.uri.path == '/work.m3u8') {
        return ResponseBody.fromString(
          playlist,
          HttpStatus.ok,
          headers: {
            Headers.contentTypeHeader: ['application/vnd.apple.mpegurl'],
          },
        );
      }
      onSegment?.call();
      final segment = int.parse(
        request.uri.pathSegments.last
            .replaceFirst('segment-', '')
            .replaceFirst('.ts', ''),
      );
      return ResponseBody.fromBytes(
        segments[segment],
        HttpStatus.ok,
        headers: {
          Headers.contentTypeHeader: ['video/mp2t'],
        },
      );
    });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final ResponseBody Function(RequestOptions) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);

  @override
  void close({bool force = false}) {}
}

Uint8List _transportSegment(
  int pts, {
  int streamType = 0x0f,
  int frameMarkerBase = 0,
}) {
  final packets = <int>[];
  packets.addAll(_psiPacket(0, _patSection()));
  packets.addAll(_psiPacket(0x1000, _pmtSection(streamType)));
  if (streamType == 0x0f) {
    final audio = [
      for (var index = 0; index < 46; index++)
        ..._adtsFrame(frameMarkerBase + index),
    ];
    final pes = _audioPes(pts, audio);
    var continuityCounter = 0;
    for (var offset = 0; offset < pes.length; offset += 184) {
      final end = (offset + 184).clamp(0, pes.length);
      packets.addAll(
        _tsPacket(
          0x0100,
          continuityCounter++ & 0x0f,
          offset == 0,
          pes.sublist(offset, end),
        ),
      );
    }
  }
  return Uint8List.fromList(packets);
}

List<int> _psiPacket(int pid, List<int> section) =>
    _tsPacket(pid, 0, true, [0, ...section]);

List<int> _tsPacket(
  int pid,
  int continuityCounter,
  bool start,
  List<int> body,
) {
  final packet = Uint8List(188)..fillRange(0, 188, 0xff);
  packet[0] = 0x47;
  packet[1] = (start ? 0x40 : 0) | ((pid >> 8) & 0x1f);
  packet[2] = pid & 0xff;
  packet[3] = 0x10 | continuityCounter;
  packet.setRange(4, 4 + body.length.clamp(0, 184), body);
  return packet;
}

List<int> _patSection() => [
  0x00,
  0xb0,
  0x0d,
  0x00,
  0x01,
  0xc1,
  0x00,
  0x00,
  0x00,
  0x01,
  0xf0,
  0x00,
  0,
  0,
  0,
  0,
];

List<int> _pmtSection(int streamType) => [
  0x02,
  0xb0,
  0x12,
  0x00,
  0x01,
  0xc1,
  0x00,
  0x00,
  0xe1,
  0x00,
  0xf0,
  0x00,
  streamType,
  0xe1,
  0x00,
  0xf0,
  0x00,
  0,
  0,
  0,
  0,
];

List<int> _audioPes(int pts, List<int> audio) {
  final pesLength = 8 + audio.length;
  final header = [
    0,
    0,
    1,
    0xc0,
    (pesLength >> 8) & 0xff,
    pesLength & 0xff,
    0x80,
    0x80,
    0x05,
    ..._encodePts(pts),
  ];
  return [...header, ...audio];
}

List<int> _encodePts(int pts) => [
  0x21 | (((pts >> 30) & 7) << 1),
  (pts >> 22) & 0xff,
  (((pts >> 15) & 0x7f) << 1) | 1,
  (pts >> 7) & 0xff,
  ((pts & 0x7f) << 1) | 1,
];

List<int> _adtsFrame(int marker) => [
  0xff,
  0xf1,
  0x4c,
  0x80,
  0x01,
  0x7f,
  0xfc,
  0x31,
  0x42,
  0x53,
  marker,
];
