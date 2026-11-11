import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/mediakit_player.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';

/// Registers actual native cache queries with only their completion time gated.
void registerNativeCacheLifecycleCases(List<int> wav,
    Future<void> Function(Future<void> Function()) nativeContract) {
  testWidgets(
      'native cache EOF reads cannot update a later load',
      (tester) => nativeContract(() async {
            final oldRead = Completer<void>();
            final releaseOld = Completer<void>();
            final oldReturned = Completer<void>();
            final bRequested = Completer<void>();
            final releaseB = Completer<void>();
            var held = false;
            final server =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            server.listen((request) async {
              final response = request.response;
              final rawRange = request.headers.value(HttpHeaders.rangeHeader);
              final start = rawRange == null
                  ? 0
                  : int.parse(rawRange.split('=')[1].split('-')[0]);
              response.headers.contentType = ContentType('audio', 'wav');
              response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
              response.statusCode = HttpStatus.partialContent;
              response.headers.set(HttpHeaders.contentRangeHeader,
                  'bytes $start-${wav.length - 1}/${wav.length}');
              response.contentLength = wav.length - start;
              if (request.uri.path == '/B.wav') {
                response.add(wav.sublist(start, start + 262144));
                await response.flush();
                if (!bRequested.isCompleted) bRequested.complete();
                await releaseB.future;
                response.add(wav.sublist(start + 262144));
              } else {
                response.add(wav.sublist(start));
              }
              await response.close();
            });
            final player = MediaKitPlayer('cache-lifecycle',
                nativePlayerConfiguration: _nativePlayerConfiguration(),
                nativePropertyReader: (native, name) async {
              if (name != 'demuxer-cache-state') {
                return native.getProperty(name);
              }
              final raw = await native.getProperty('demuxer-cache-state');
              final path = await native.getProperty('path');
              final state = raw.isEmpty ? null : jsonDecode(raw);
              if (!held &&
                  path.endsWith('/A.wav') &&
                  state?['eof'] == true &&
                  state?['eof-cached'] == true) {
                held = true;
                oldRead.complete();
                await releaseOld.future;
                oldReturned.complete();
              }
              return raw;
            });
            final events = <PlaybackEventMessage>[];
            final errors = <Object>[];
            final subscription = player.playbackEventMessageStream
                .listen(events.add, onError: errors.add);
            LoadRequest source(String id) => LoadRequest(
                audioSourceMessage: ProgressiveAudioSourceMessage(
                    id: id, uri: 'http://127.0.0.1:${server.port}/$id.wav'));
            try {
              await player.ready();
              await player
                  .load(source('A'))
                  .timeout(const Duration(seconds: 10));
              await oldRead.future.timeout(const Duration(seconds: 10));
              final bLoad = player.load(source('B'));
              final outcome = bLoad.then<Object>((value) => value,
                  onError: (Object error) => error);
              await bRequested.future.timeout(const Duration(seconds: 10));
              expect(await outcome.timeout(const Duration(seconds: 10)),
                  isA<LoadResponse>());
              await player.playbackEventMessageStream
                  .firstWhere((event) =>
                      event.bufferedPosition > Duration.zero &&
                      event.bufferedPosition < const Duration(seconds: 24))
                  .timeout(const Duration(seconds: 10));
              expect(events.last.bufferedPosition, greaterThan(Duration.zero));
              expect(events.last.bufferedPosition,
                  lessThan(const Duration(seconds: 24)));
              final marker = events.length;
              releaseOld.complete();
              await oldReturned.future.timeout(const Duration(seconds: 10));
              await player.setVolume(SetVolumeRequest(volume: .5));
              expect(
                  events.skip(marker).every((event) =>
                      event.bufferedPosition < const Duration(seconds: 24)),
                  isTrue,
                  reason: 'Old A EOF must not fill the uncached tail of B');
              expect(events.last.bufferedPosition,
                  lessThan(const Duration(seconds: 24)));
              final completeBuffer = player.playbackEventMessageStream
                  .firstWhere((event) =>
                      event.bufferedPosition == const Duration(seconds: 24));
              releaseB.complete();
              await completeBuffer.timeout(const Duration(seconds: 10));
              expect(errors, isEmpty);
            } finally {
              if (!releaseOld.isCompleted) releaseOld.complete();
              if (!releaseB.isCompleted) releaseB.complete();
              await player.release();
              await subscription.cancel();
              await server.close(force: true);
            }
          }));

  testWidgets(
      'native cache query errors after release stay retired',
      (tester) => nativeContract(() async {
            final captured = Completer<void>();
            final releaseRead = Completer<void>();
            final returned = Completer<void>();
            var held = false;
            var released = false;
            final server =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            server.listen((request) async {
              request.response.headers.contentType =
                  ContentType('audio', 'wav');
              request.response.contentLength = wav.length;
              request.response.add(wav);
              await request.response.close();
            });
            final player = MediaKitPlayer('retired-cache-read',
                nativePlayerConfiguration: _nativePlayerConfiguration(),
                nativePropertyReader: (native, name) async {
              if (name != 'demuxer-cache-state') {
                return native.getProperty(name);
              }
              final raw = await native.getProperty('demuxer-cache-state');
              if (!held && raw.isNotEmpty && jsonDecode(raw)['eof'] == true) {
                held = true;
                captured.complete();
                await releaseRead.future;
                try {
                  // This is a real getProperty on the now-disposed NativePlayer.
                  return await native.getProperty('demuxer-cache-state');
                } finally {
                  returned.complete();
                }
              }
              return raw;
            });
            final errors = <Object>[];
            final subscription = player.playbackEventMessageStream
                .listen((_) {}, onError: errors.add);
            try {
              await player.ready();
              await player
                  .load(LoadRequest(
                      audioSourceMessage: ProgressiveAudioSourceMessage(
                          id: 'retired-A',
                          uri: 'http://127.0.0.1:${server.port}/A.wav')))
                  .timeout(const Duration(seconds: 10));
              await captured.future.timeout(const Duration(seconds: 10));
              await player.release();
              released = true;
              releaseRead.complete();
              await returned.future.timeout(const Duration(seconds: 10));
              await Future<void>.delayed(Duration.zero);
              expect(errors, isEmpty);
            } finally {
              if (!releaseRead.isCompleted) releaseRead.complete();
              if (!released) await player.release();
              await subscription.cancel();
              await server.close(force: true);
            }
          }));

  testWidgets(
      'late buffering query cannot overwrite native ready',
      (tester) => nativeContract(() async {
            final captured = Completer<void>();
            final releaseRead = Completer<void>();
            final returned = Completer<void>();
            final releaseTail = Completer<void>();
            var held = false;
            NativePlayer? nativePlayer;
            final server =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            server.listen((request) async {
              request.response.headers.contentType =
                  ContentType('audio', 'wav');
              request.response.contentLength = wav.length;
              if (request.uri.path == '/A.wav') {
                request.response.add(wav.sublist(0, 262144));
                await request.response.flush();
                await releaseTail.future;
                request.response.add(wav.sublist(262144));
              } else {
                request.response.add(wav);
              }
              await request.response.close();
            });
            final player = MediaKitPlayer('late-buffering',
                nativePlayerConfiguration: _nativePlayerConfiguration(),
                nativePropertyReader: (native, name) async {
              nativePlayer = native;
              final raw = await native.getProperty(name);
              if (name == 'eof-reached' && !held && raw == 'no') {
                held = true;
                captured.complete();
                await releaseRead.future;
                returned.complete();
              }
              return raw;
            });
            final events = <PlaybackEventMessage>[];
            final errors = <Object>[];
            final subscription = player.playbackEventMessageStream
                .listen(events.add, onError: errors.add);
            try {
              await player.ready();
              final load = player.load(LoadRequest(
                  audioSourceMessage: ConcatenatingAudioSourceMessage(
                      id: 'buffering-list',
                      useLazyPreparation: false,
                      shuffleOrder: [
                    0,
                    1
                  ],
                      children: [
                    for (final id in ['A', 'B'])
                      ProgressiveAudioSourceMessage(
                          id: id,
                          uri: 'http://127.0.0.1:${server.port}/$id.wav')
                  ])));
              await load.timeout(const Duration(seconds: 10));
              await player.setSpeed(SetSpeedRequest(speed: 4));
              await player.play(PlayRequest());
              await captured.future.timeout(const Duration(seconds: 10));
              final becameReady = player.playbackEventMessageStream.firstWhere(
                  (event) =>
                      event.processingState == ProcessingStateMessage.ready);
              releaseTail.complete();
              await becameReady.timeout(const Duration(seconds: 10));
              expect(events.last.processingState, ProcessingStateMessage.ready);
              await player.pause(PauseRequest());
              final native = nativePlayer!;
              if (native.state.buffering) {
                await native.stream.buffering
                    .firstWhere((buffering) => !buffering)
                    .timeout(const Duration(seconds: 10));
              }
              expect(native.state.playlist.index, 0);
              expect(
                  native.state.playlist.medias[native.state.playlist.index].uri,
                  endsWith('/A.wav'));
              final marker = events.length;
              releaseRead.complete();
              await returned.future.timeout(const Duration(seconds: 10));
              await Future<void>.delayed(Duration.zero);
              expect(events.skip(marker).map((event) => event.processingState),
                  isNot(contains(ProcessingStateMessage.buffering)));
              expect(events.last.processingState, ProcessingStateMessage.ready);
              expect(errors, isEmpty);
            } finally {
              if (!releaseRead.isCompleted) releaseRead.complete();
              if (!releaseTail.isCompleted) releaseTail.complete();
              await player.release();
              await subscription.cancel();
              await server.close(force: true);
            }
          }));

  testWidgets(
      'old EOF read cannot fill a different seek range',
      (tester) => nativeContract(() async {
            final captured = Completer<void>();
            final releaseRead = Completer<void>();
            final returned = Completer<void>();
            var armed = false;
            var held = false;
            var configured = false;
            NativePlayer? nativePlayer;
            final savedBuffer = JustAudioMediaKit.bufferSize;
            JustAudioMediaKit.bufferSize = 128 * 1024;
            final server =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            server.listen((request) async {
              final range = request.headers.value(HttpHeaders.rangeHeader);
              final start = range == null
                  ? 0
                  : int.parse(range.split('=')[1].split('-')[0]);
              request.response.headers.contentType =
                  ContentType('audio', 'wav');
              request.response.headers
                  .set(HttpHeaders.acceptRangesHeader, 'bytes');
              request.response.statusCode = HttpStatus.partialContent;
              request.response.headers.set(HttpHeaders.contentRangeHeader,
                  'bytes $start-${wav.length - 1}/${wav.length}');
              request.response.contentLength = wav.length - start;
              request.response.add(wav.sublist(start));
              await request.response.close();
            });
            final player = MediaKitPlayer('seek-cache-range',
                nativePlayerConfiguration: _nativePlayerConfiguration(),
                nativePropertyReader: (native, name) async {
              nativePlayer = native;
              if (!configured) {
                configured = true;
                await native.setProperty(
                    'demuxer-max-back-bytes', '${128 * 1024}');
                await native.setProperty('demuxer-readahead-secs', '1');
              }
              final raw = await native.getProperty(name);
              if (name == 'demuxer-cache-state' &&
                  raw.isNotEmpty &&
                  armed &&
                  !held &&
                  jsonDecode(raw)['eof'] == true) {
                held = true;
                captured.complete();
                await releaseRead.future;
                returned.complete();
              }
              return raw;
            });
            final events = <PlaybackEventMessage>[];
            final errors = <Object>[];
            final subscription = player.playbackEventMessageStream
                .listen(events.add, onError: errors.add);
            try {
              await player.ready();
              await player
                  .load(LoadRequest(
                      audioSourceMessage: ProgressiveAudioSourceMessage(
                          id: 'seek-A',
                          uri: 'http://127.0.0.1:${server.port}/A.wav')))
                  .timeout(const Duration(seconds: 10));
              armed = true;
              await player
                  .seek(SeekRequest(position: const Duration(seconds: 23)));
              await captured.future.timeout(const Duration(seconds: 10));
              await player
                  .seek(SeekRequest(position: const Duration(seconds: 5)));
              final watch = Stopwatch()..start();
              while (true) {
                final state = jsonDecode(
                    await nativePlayer!.getProperty('demuxer-cache-state'));
                if (state['eof'] == false &&
                    state['eof-cached'] == true &&
                    events.last.bufferedPosition > const Duration(seconds: 5) &&
                    events.last.bufferedPosition <
                        const Duration(seconds: 20)) {
                  break;
                }
                if (watch.elapsed > const Duration(seconds: 10)) {
                  throw TimeoutException(
                      'Actual discontinuous seek cache: $state');
                }
                await Future<void>.delayed(const Duration(milliseconds: 25));
              }
              final marker = events.length;
              releaseRead.complete();
              await returned.future.timeout(const Duration(seconds: 10));
              await player.setVolume(SetVolumeRequest(volume: .5));
              expect(
                  events.skip(marker).every((event) =>
                      event.bufferedPosition < const Duration(seconds: 24)),
                  isTrue,
                  reason:
                      'The old terminal range must not fill the current range');
              expect(events.last.bufferedPosition,
                  lessThan(const Duration(seconds: 24)));
              expect(errors, isEmpty);
            } finally {
              if (!releaseRead.isCompleted) releaseRead.complete();
              await player.release();
              await subscription.cancel();
              await server.close(force: true);
              JustAudioMediaKit.bufferSize = savedBuffer;
            }
          }));

  testWidgets(
      'old EOF read cannot publish inside a natural file boundary',
      (tester) => nativeContract(() async {
            final captured = Completer<void>();
            final releaseRead = Completer<void>();
            final returned = Completer<void>();
            final unloading = Completer<void>();
            final releaseUnload = Completer<void>();
            var armed = false;
            var held = false;
            NativePlayer? nativePlayer;
            final server =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            server.listen((request) async {
              final response = request.response;
              final range = request.headers.value(HttpHeaders.rangeHeader);
              final bounds = range?.substring('bytes='.length).split('-');
              final start = bounds == null ? 0 : int.parse(bounds.first);
              final end = bounds == null || bounds.last.isEmpty
                  ? wav.length - 1
                  : int.parse(bounds.last);
              response.headers.contentType = ContentType('audio', 'wav');
              response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
              if (range != null) {
                response.statusCode = HttpStatus.partialContent;
                response.headers.set(HttpHeaders.contentRangeHeader,
                    'bytes $start-$end/${wav.length}');
              }
              response.contentLength = end - start + 1;
              response.add(wav.sublist(start, end + 1));
              await response.close();
            });
            final player = MediaKitPlayer('boundary-cache',
                nativePlayerConfiguration: _nativePlayerConfiguration(),
                nativePropertyReader: (native, name) async {
              nativePlayer = native;
              final raw = await native.getProperty(name);
              if (name == 'demuxer-cache-state' &&
                  raw.isNotEmpty &&
                  armed &&
                  !held &&
                  jsonDecode(raw)['eof'] == true) {
                held = true;
                captured.complete();
                await releaseRead.future;
                returned.complete();
              }
              return raw;
            });
            final events = <PlaybackEventMessage>[];
            final errors = <Object>[];
            final subscription = player.playbackEventMessageStream
                .listen(events.add, onError: errors.add);
            try {
              await player.ready();
              await player
                  .load(LoadRequest(
                      audioSourceMessage: ConcatenatingAudioSourceMessage(
                          id: 'boundary-list',
                          useLazyPreparation: false,
                          shuffleOrder: [
                        0,
                        1
                      ],
                          children: [
                        for (final id in ['A', 'B'])
                          ProgressiveAudioSourceMessage(
                              id: id,
                              uri: 'http://127.0.0.1:${server.port}/$id.wav')
                      ])))
                  .timeout(const Duration(seconds: 10));
              armed = true;
              await player
                  .seek(SeekRequest(position: const Duration(seconds: 23)));
              await captured.future.timeout(const Duration(seconds: 10));
              nativePlayer!.onUnloadHooks.add(() async {
                if (!unloading.isCompleted) {
                  unloading.complete();
                  await releaseUnload.future;
                }
              });
              final completed =
                  nativePlayer!.stream.completed.firstWhere((value) => value);
              await player.setSpeed(SetSpeedRequest(speed: 4));
              await player.play(PlayRequest());
              await unloading.future.timeout(const Duration(seconds: 10));
              await completed.timeout(const Duration(seconds: 10));
              expect(events.last.currentIndex, 0);
              final marker = events.length;
              releaseRead.complete();
              await returned.future.timeout(const Duration(seconds: 10));
              await Future<void>.delayed(Duration.zero);
              expect(events.skip(marker), isEmpty,
                  reason: 'A must stay atomic while native unload waits for B');
              final next = player.playbackEventMessageStream.firstWhere(
                  (event) =>
                      event.currentIndex == 1 &&
                      event.updatePosition > Duration.zero);
              releaseUnload.complete();
              await next.timeout(const Duration(seconds: 10));
              expect(errors, isEmpty);
            } finally {
              if (!releaseRead.isCompleted) releaseRead.complete();
              if (!releaseUnload.isCompleted) releaseUnload.complete();
              await player.release();
              await subscription.cancel();
              await server.close(force: true);
            }
          }));
}

NativePlayerConfiguration? _nativePlayerConfiguration() {
  if (!Platform.isWindows) return null;
  return (native) async {
    await native.setProperty('ao', 'null');
    await native.setProperty('audio-exclusive', 'no');
    expect(await native.getProperty('options/ao'), 'null');
  };
}
