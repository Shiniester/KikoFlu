import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/src/services/remote_asset_cache.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/video_download_task.dart';
import 'package:kikoeru_flutter/src/videos/video_downloads.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

void main() {
  late Directory root;
  late SharedPreferences preferences;
  late HttpClient httpClient;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    root = await Directory.systemTemp.createTemp('kikoflu-video-downloads-');
    httpClient = HttpClient()..findProxy = (_) => 'DIRECT';
    _activeTest = _TestContext(
      root: root,
      preferences: preferences,
      httpClient: httpClient,
      servers: [],
      services: [],
      libraries: [],
      sourceClients: [],
    );
  });

  tearDown(() async {
    for (final service in _activeTest.services) {
      service.dispose();
    }
    for (final library in _activeTest.libraries) {
      library.dispose();
    }
    for (final sourceClient in _activeTest.sourceClients) {
      sourceClient.dispose();
    }
    httpClient.close(force: true);
    for (final server in _activeTest.servers) {
      await server.close(force: true);
    }
    await root.delete(recursive: true);
  });

  test(
    'downloads an MP4 and retries after rejecting an HTML challenge page',
    () async {
      var validResponse = false;
      final server = await _server((request) async {
        if (validResponse) {
          await _send(request, _mp4Fixture(), contentType: 'video/mp4');
        } else {
          await _send(
            request,
            utf8.encode('<!doctype html><html>verification</html>'),
            contentType: 'text/html; charset=utf-8',
          );
        }
      });
      final video = _video(server, '/video/one');
      final stream = VideoStream(label: '720p', url: _url(server, '/one.mp4'));
      final sourceClient = _fixtureClient(video, stream);
      final downloads = await _downloads(sourceClient);

      await downloads.add(video, stream);
      await _until(
        downloads,
        (task) => task.status == VideoDownloadStatus.failed,
      );
      expect(
        await File(downloads.forVideo(video.id)!.localPath!).exists(),
        isFalse,
      );
      expect(
        await File('${downloads.forVideo(video.id)!.localPath}.part').exists(),
        isFalse,
      );

      validResponse = true;
      await downloads.retry(video.id);
      await _until(
        downloads,
        (task) => task.status == VideoDownloadStatus.completed,
      );
      expect(sourceClient.detailsCalls, 2);
      expect(
        await File(downloads.forVideo(video.id)!.localPath!).readAsBytes(),
        _mp4Fixture(),
      );
    },
  );

  test(
    'pause restores as paused and resumes an MP4 with an HTTP byte range',
    () async {
      final firstChunkSent = Completer<void>();
      final releaseFirstResponse = Completer<void>();
      final ranges = <String?>[];
      final bytes = _mp4Fixture();
      const firstChunkLength = 96;
      final server = await _server((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        ranges.add(range);
        if (range == null && !firstChunkSent.isCompleted) {
          final response = request.response;
          response.bufferOutput = false;
          response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
          response.contentLength = bytes.length;
          try {
            response.add(bytes.sublist(0, firstChunkLength));
            await response.flush();
            firstChunkSent.complete();
            await releaseFirstResponse.future;
            response.add(bytes.sublist(firstChunkLength));
            await response.close();
          } catch (_) {
            if (!firstChunkSent.isCompleted) firstChunkSent.complete();
          }
          return;
        }
        final start = int.parse(
          range!.replaceFirst('bytes=', '').replaceFirst('-', ''),
        );
        final response = request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp4')
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${bytes.length - 1}/${bytes.length}',
          )
          ..contentLength = bytes.length - start;
        response.add(bytes.sublist(start));
        await response.close();
      });
      final video = _video(server, '/video/pause');
      final stream = VideoStream(
        label: '1080p',
        url: _url(server, '/pause.mp4'),
      );
      final firstSourceClient = _fixtureClient(video, stream);
      final firstDownloads = await _downloads(firstSourceClient);

      await firstDownloads.add(video, stream);
      await firstChunkSent.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError(
          'Server did not flush the first Range-test chunk; '
          'task=${_taskState(firstDownloads, video.id)}',
        ),
      );
      await _until(firstDownloads, (task) => task.progress > 0);
      await firstDownloads.pause(video.id);
      expect(
        firstDownloads.forVideo(video.id)!.status,
        VideoDownloadStatus.paused,
      );
      final partial = File(
        '${firstDownloads.forVideo(video.id)!.localPath}.part',
      );
      expect(await partial.length(), firstChunkLength);
      firstDownloads.dispose();
      _activeTest.services.remove(firstDownloads);
      firstSourceClient.dispose();
      _activeTest.sourceClients.remove(firstSourceClient);

      releaseFirstResponse.complete();
      final resumedSourceClient = _fixtureClient(video, stream);
      final resumedDownloads = await _downloads(resumedSourceClient);
      expect(
        resumedDownloads.forVideo(video.id)!.status,
        VideoDownloadStatus.paused,
      );
      await resumedDownloads.resume(video.id);
      await _until(
        resumedDownloads,
        (task) => task.status == VideoDownloadStatus.completed,
      );

      expect(ranges, [null, 'bytes=$firstChunkLength-']);
      expect(
        await File(
          resumedDownloads.forVideo(video.id)!.localPath!,
        ).readAsBytes(),
        bytes,
      );
    },
  );

  test(
    'deleting an active task waits for cancellation before removing its directory',
    () async {
      final firstChunkSent = Completer<void>();
      final releaseResponse = Completer<void>();
      final bytes = _mp4Fixture();
      final server = await _server((request) async {
        final response = request.response
          ..bufferOutput = false
          ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp4')
          ..contentLength = bytes.length;
        try {
          response.add(bytes.sublist(0, 64));
          await response.flush();
          firstChunkSent.complete();
          await releaseResponse.future;
          response.add(bytes.sublist(64));
          await response.close();
        } catch (_) {
          if (!firstChunkSent.isCompleted) firstChunkSent.complete();
        }
      });
      final video = _video(server, '/video/delete');
      final stream = VideoStream(
        label: '720p',
        url: _url(server, '/delete.mp4'),
      );
      final sourceClient = _fixtureClient(video, stream);
      final downloads = await _downloads(sourceClient);

      await downloads.add(video, stream);
      await firstChunkSent.future.timeout(const Duration(seconds: 5));
      final directory = Directory(
        downloads.forVideo(video.id)!.localPath!,
      ).parent;
      await downloads.remove(video.id);
      expect(downloads.forVideo(video.id), isNull);
      expect(await directory.exists(), isFalse);

      releaseResponse.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await directory.exists(), isFalse);
    },
  );

  test(
    'deleting the only queued task does not keep restarting the queue',
    () async {
      final firstChunkSent = Completer<void>();
      final releaseResponse = Completer<void>();
      final bytes = _mp4Fixture();
      const firstChunkLength = 96;
      final server = await _server((request) async {
        final response = request.response
          ..bufferOutput = false
          ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp4')
          ..contentLength = bytes.length;
        try {
          response.add(bytes.sublist(0, firstChunkLength));
          await response.flush();
          firstChunkSent.complete();
          await releaseResponse.future;
          response.add(bytes.sublist(firstChunkLength));
          await response.close();
        } catch (_) {
          if (!firstChunkSent.isCompleted) firstChunkSent.complete();
        }
      });
      final activeVideo = _video(server, '/video/active');
      final stream = VideoStream(
        label: '720p',
        url: _url(server, '/queue.mp4'),
      );
      final sourceClient = _fixtureClient(activeVideo, stream);
      final downloads = await _downloads(sourceClient);
      final queuedVideo = VideoItem(
        id: 'queued-video',
        title: 'Queued video',
        pageUrl: _url(server, '/video/queued'),
      );
      final queuedDirectory = Directory(
        '${_activeTest.root.path}/${base64Url.encode(utf8.encode(queuedVideo.id)).replaceAll('=', '')}',
      );
      await queuedDirectory.create(recursive: true);
      for (var index = 0; index < 1024; index++) {
        await File('${queuedDirectory.path}/$index.tmp').create();
      }

      await downloads.add(activeVideo, stream);
      await firstChunkSent.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError(
          'Server did not flush the first queue-test chunk; '
          'task=${_taskState(downloads, activeVideo.id)}',
        ),
      );
      await _until(downloads, (task) => task.progress > 0);
      await downloads.add(queuedVideo, stream);

      final removal = downloads.remove(queuedVideo.id);
      await Future<void>.delayed(Duration.zero);
      releaseResponse.complete();
      await removal.timeout(const Duration(seconds: 5));
      await _until(
        downloads,
        (task) => task.status == VideoDownloadStatus.completed,
        videoId: activeVideo.id,
      );

      expect(downloads.forVideo(queuedVideo.id), isNull);
      expect(await queuedDirectory.exists(), isFalse);
    },
  );

  test(
    'resolves a master playlist and saves segments, map, and key for offline use',
    () async {
      final sourceRequests = <String>[];
      final sourceCookies = <String?>[];
      late HttpServer cdnServer;
      final sourceServer = await _server((request) async {
        sourceRequests.add(request.uri.path);
        sourceCookies.add(request.headers.value(HttpHeaders.cookieHeader));
        if (request.uri.path == '/master.m3u8') {
          await _send(
            request,
            utf8.encode('''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=640x360
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=1280x720
high.m3u8
'''),
            contentType: 'application/vnd.apple.mpegurl',
          );
        } else if (request.uri.path == '/high.m3u8') {
          await _send(
            request,
            utf8.encode('''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MAP:URI="${_url(cdnServer, '/init.mp4')}"
#EXT-X-KEY:METHOD=AES-128,URI="${_url(cdnServer, '/key.bin')}",IV=0x00000000000000000000000000000001
#EXTINF:1.0,
${_url(cdnServer, '/segment.m4s')}
#EXT-X-KEY:METHOD=NONE
#EXT-X-ENDLIST
'''),
            contentType: 'application/vnd.apple.mpegurl',
          );
        } else if (request.uri.path == '/low.m3u8') {
          fail('the lower-bandwidth variant should not be requested');
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      });
      final cdnHeaders = <Map<String, String?>>[];
      cdnServer = await _server((request) async {
        cdnHeaders.add({
          HttpHeaders.cookieHeader: request.headers.value(
            HttpHeaders.cookieHeader,
          ),
          HttpHeaders.authorizationHeader: request.headers.value(
            HttpHeaders.authorizationHeader,
          ),
          HttpHeaders.refererHeader: request.headers.value(
            HttpHeaders.refererHeader,
          ),
          'origin': request.headers.value('origin'),
        });
        switch (request.uri.path) {
          case '/init.mp4':
            await _send(request, _ftypFixture(), contentType: 'video/mp4');
            break;
          case '/key.bin':
            await _send(request, List<int>.filled(16, 3));
            break;
          case '/segment.m4s':
            await _send(
              request,
              List<int>.filled(32, 7),
              contentType: 'video/iso.segment',
            );
            break;
          default:
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            break;
        }
      });
      final video = _video(sourceServer, '/video/hls');
      final stream = VideoStream(
        label: 'Auto',
        url: _url(sourceServer, '/master.m3u8'),
        headers: const {
          HttpHeaders.cookieHeader: 'source=session',
          HttpHeaders.authorizationHeader: 'Bearer source-secret',
          HttpHeaders.userAgentHeader: 'KikoFlu test',
          HttpHeaders.refererHeader: 'https://missav.ai/video/hls',
          'origin': 'https://missav.ai',
        },
        isHls: true,
      );
      final sourceClient = _fixtureClient(video, stream);
      final downloads = await _downloads(sourceClient);

      await downloads.add(video, stream);
      await _until(
        downloads,
        (task) => task.status == VideoDownloadStatus.completed,
      );

      expect(sourceRequests, ['/master.m3u8', '/high.m3u8']);
      expect(sourceCookies.first, 'source=session');
      expect(cdnHeaders, hasLength(3));
      expect(
        cdnHeaders.every(
          (headers) =>
              headers[HttpHeaders.cookieHeader] == null &&
              headers[HttpHeaders.authorizationHeader] == null,
        ),
        isTrue,
      );
      expect(
        cdnHeaders.every(
          (headers) =>
              headers[HttpHeaders.refererHeader] ==
                  'https://missav.ai/video/hls' &&
              headers['origin'] == 'https://missav.ai',
        ),
        isTrue,
      );
      final task = downloads.forVideo(video.id)!;
      final manifest = await File(task.localPath!).readAsString();
      expect(manifest, contains('URI="maps/0000.mp4"'));
      expect(manifest, contains('URI="keys/0000.key"'));
      expect(manifest, contains('segments/000000.m4s'));
      expect(manifest, isNot(contains('http://')));
      for (final path in [
        'maps/0000.mp4',
        'keys/0000.key',
        'segments/000000.m4s',
      ]) {
        expect(
          await File('${File(task.localPath!).parent.path}/$path').exists(),
          isTrue,
        );
      }
      final restored = await _downloads(sourceClient);
      expect(
        restored.forVideo(video.id)!.status,
        VideoDownloadStatus.completed,
      );
      expect(sourceClient.detailsCalls, 1);
    },
  );

  test(
    'downloads an AES-128 encrypted HLS map declared after its key',
    () async {
      late HttpServer cdnServer;
      final encryptedMap = List<int>.filled(32, 9);
      final encryptedSegment = List<int>.filled(32, 7);
      final sourceServer = await _server((request) async {
        await _send(
          request,
          utf8.encode('''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-KEY:METHOD=AES-128,URI="${_url(cdnServer, '/key.bin')}",IV=0x00000000000000000000000000000001
#EXT-X-MAP:URI="${_url(cdnServer, '/init.mp4')}"
#EXTINF:1.0,
${_url(cdnServer, '/segment.m4s')}
#EXT-X-ENDLIST
'''),
          contentType: 'application/vnd.apple.mpegurl',
        );
      });
      cdnServer = await _server((request) async {
        switch (request.uri.path) {
          case '/key.bin':
            await _send(request, List<int>.filled(16, 3));
            break;
          case '/init.mp4':
            await _send(
              request,
              encryptedMap,
              contentType: 'application/octet-stream',
            );
            break;
          case '/segment.m4s':
            await _send(
              request,
              encryptedSegment,
              contentType: 'video/iso.segment',
            );
            break;
          default:
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            break;
        }
      });
      final video = _video(sourceServer, '/video/encrypted-map');
      final stream = VideoStream(
        label: 'Auto',
        url: _url(sourceServer, '/encrypted.m3u8'),
        isHls: true,
      );
      final sourceClient = _fixtureClient(video, stream);
      final downloads = await _downloads(sourceClient);

      await downloads.add(video, stream);
      await _until(
        downloads,
        (task) => task.status == VideoDownloadStatus.completed,
      );

      final task = downloads.forVideo(video.id)!;
      final directory = File(task.localPath!).parent;
      expect(
        await File('${directory.path}/maps/0000.mp4').readAsBytes(),
        encryptedMap,
      );
      expect(
        await File('${directory.path}/segments/000000.m4s').readAsBytes(),
        encryptedSegment,
      );
      expect(await File('${directory.path}/keys/0000.key').length(), 16);
    },
  );

  test(
    'task persistence excludes stream credentials and restores unfinished work paused',
    () async {
      const video = VideoItem(
        id: 'video-auth',
        title: 'Private video',
        pageUrl:
            'https://missav.ai/video/auth?access_token=page-secret&lang=en',
        releaseDate: '2024-03-02',
        actors: [
          VideoLink(
            label: 'Sample actor',
            url: 'https://missav.ai/cn/actresses/sample',
            kind: VideoLinkKind.actor,
          ),
        ],
        tags: [
          VideoLink(
            label: 'Drama',
            url: 'https://missav.ai/cn/genres/drama',
            kind: VideoLinkKind.category,
          ),
        ],
        hasSubtitles: true,
        isUncensored: true,
      );
      const stream = VideoStream(
        label: '720p',
        url: 'https://cdn.example/auth.mp4?token=stream-secret',
        headers: {
          HttpHeaders.cookieHeader: 'sid=source-secret',
          HttpHeaders.authorizationHeader: 'Bearer source-secret',
        },
      );
      final task = VideoDownloadTask(
        id: video.id,
        video: video,
        quality: stream.label,
        isHls: false,
        status: VideoDownloadStatus.paused,
      );
      await preferences.setString(
        'video_download_tasks_v1',
        jsonEncode([task.toJson()]),
      );
      final taskJson = preferences.getString('video_download_tasks_v1')!;
      expect(taskJson, isNot(contains('page-secret')));
      expect(taskJson, contains('lang=en'));

      final restoredClient = _fixtureClient(video, stream);
      final restored = await _downloads(restoredClient);
      expect(restored.forVideo(video.id)!.status, VideoDownloadStatus.paused);
      final restoredVideo = restored.forVideo(video.id)!.video;
      expect(restoredVideo.releaseDate, video.releaseDate);
      expect(restoredVideo.actors.single.label, 'Sample actor');
      expect(restoredVideo.tags.single.label, 'Drama');
      expect(restoredVideo.hasSubtitles, isTrue);
      expect(restoredVideo.isUncensored, isTrue);
    },
  );
}

Future<VideoDownloads> _downloads(_FixtureMissavClient sourceClient) async {
  final test = _activeTest;
  final service = VideoDownloads(
    client: sourceClient,
    library: test.library,
    rootDirectory: test.root,
    preferences: test.preferences,
    transport: RemoteAssetTransportHolder.transport(test.httpClient),
  );
  test.services.add(service);
  await service.initialize();
  return service;
}

// The test harness is set for each test by [_server] and [_fixtureClient].
late _TestContext _activeTest;

Future<HttpServer> _server(Future<void> Function(HttpRequest) handle) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _activeTest.servers.add(server);
  server.listen(handle);
  return server;
}

VideoItem _video(HttpServer server, String path) => VideoItem(
  id: path.split('/').last,
  title: 'Video',
  pageUrl: _url(server, path),
);

String _url(HttpServer server, String path) =>
    'http://${server.address.host}:${server.port}$path';

_FixtureMissavClient _fixtureClient(VideoItem video, VideoStream stream) {
  final client = _FixtureMissavClient(
    (item) async => VideoDetails(video: item, streams: [stream]),
  );
  _activeTest.sourceClients.add(client);
  return client;
}

Future<void> _send(
  HttpRequest request,
  List<int> bytes, {
  String? contentType,
}) async {
  final response = request.response..contentLength = bytes.length;
  if (contentType != null) {
    response.headers.set(HttpHeaders.contentTypeHeader, contentType);
  }
  response.add(bytes);
  await response.close();
}

Future<void> _until(
  VideoDownloads downloads,
  bool Function(VideoDownloadTask) predicate, {
  String? videoId,
}) async {
  final id = videoId ?? downloads.tasks.single.id;
  final existing = downloads.forVideo(id);
  if (existing != null && predicate(existing)) return;
  final signal = Completer<void>();
  void listener() {
    final task = downloads.forVideo(id);
    if (task != null && predicate(task) && !signal.isCompleted) {
      signal.complete();
    }
  }

  downloads.addListener(listener);
  try {
    listener();
    await signal.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw StateError(
        'Timed out waiting for video task $id; '
        'task=${_taskState(downloads, id)}',
      ),
    );
  } finally {
    downloads.removeListener(listener);
  }
}

String _taskState(VideoDownloads downloads, String id) {
  final task = downloads.forVideo(id);
  if (task == null) {
    return 'missing; tasks=${downloads.tasks.map((value) => value.id).toList()}';
  }
  return 'status=${task.status.name}, progress=${task.progress}, error=${task.error}';
}

Uint8List _mp4Fixture() {
  final builder = BytesBuilder(copy: false)
    ..add(_ftypFixture())
    ..add([0, 0, 0, 108, ...ascii.encode('mdat'), ...List<int>.filled(100, 0)]);
  return builder.takeBytes();
}

Uint8List _ftypFixture() => Uint8List.fromList([
  0,
  0,
  0,
  20,
  ...ascii.encode('ftyp'),
  ...ascii.encode('isom'),
  0,
  0,
  0,
  0,
  ...ascii.encode('isom'),
]);

class _TestContext {
  _TestContext({
    required this.root,
    required this.preferences,
    required this.httpClient,
    required this.servers,
    required this.services,
    required this.libraries,
    required this.sourceClients,
  });

  final Directory root;
  final SharedPreferences preferences;
  final HttpClient httpClient;
  final List<HttpServer> servers;
  final List<VideoDownloads> services;
  final List<VideoLibrary> libraries;
  final List<_FixtureMissavClient> sourceClients;

  VideoLibrary get library {
    final value = VideoLibrary(preferences: preferences);
    libraries.add(value);
    return value;
  }
}

class RemoteAssetTransportHolder {
  static RemoteAssetTransport transport(HttpClient client) =>
      HttpRemoteAssetTransport(client: client);
}

class _FixtureMissavClient extends MissavClient {
  _FixtureMissavClient(this.resolve) : super(dio: Dio());

  final Future<VideoDetails> Function(VideoItem) resolve;
  int detailsCalls = 0;

  @override
  Future<VideoDetails> details(VideoItem item) {
    detailsCalls++;
    return resolve(item);
  }
}
