import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/download_task.dart';
import 'package:kikoeru_flutter/src/services/download_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _Network extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousOverrides = HttpOverrides.current;

  setUpAll(() => HttpOverrides.global = _Network());
  tearDownAll(() => HttpOverrides.global = previousOverrides);

  late Directory downloadRoot;
  late DownloadService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await StorageService.initCritical(preferences: preferences);
    downloadRoot = await Directory.systemTemp.createTemp(
      'kikoflu-force-download-',
    );
    await preferences.setString('custom_download_path', downloadRoot.path);
    service = DownloadService.instance;
  });

  tearDown(() async {
    if (await downloadRoot.exists()) {
      await downloadRoot.delete(recursive: true);
    }
  });

  test(
    'force download removes an old checkpoint and starts without Range',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final rangeHeaders = <String?>[];
      server.listen((request) async {
        rangeHeaders.add(request.headers.value(HttpHeaders.rangeHeader));
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = 4
          ..add(const [9, 8, 7, 6]);
        await request.response.close();
      });

      final workId = DateTime.now().microsecondsSinceEpoch;
      const fileName = 'track.mp3';
      final workDirectory = Directory(p.join(downloadRoot.path, '$workId'));
      await workDirectory.create(recursive: true);
      final target = File(p.join(workDirectory.path, fileName));
      final checkpoint = File('${target.path}.downloading');
      await checkpoint.writeAsBytes(const [1, 2]);

      final task = await service.addTask(
        workId: workId,
        workTitle: 'Work',
        fileName: fileName,
        downloadUrl: 'http://127.0.0.1:${server.port}/track.mp3',
        hash: 'force-$workId',
        forceDownload: true,
      );
      await _waitForStatus(service, task.id, DownloadStatus.completed);

      expect(rangeHeaders, hasLength(1));
      expect(rangeHeaders.single, isNull);
      expect(await target.readAsBytes(), const [9, 8, 7, 6]);
      expect(await checkpoint.exists(), isFalse);
    },
  );

  test('force request does not restart an in-flight manual task', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestStarted = Completer<void>();
    final finishResponse = Completer<void>();
    final responseFinished = Completer<void>();
    var requestCount = 0;
    server.listen((request) async {
      requestCount++;
      final response = request.response
        ..bufferOutput = false
        ..statusCode = HttpStatus.ok
        ..contentLength = 6;
      response.add(const [1, 2, 3]);
      await response.flush();
      requestStarted.complete();
      try {
        await finishResponse.future;
        response.add(const [4, 5, 6]);
        await response.close();
      } finally {
        responseFinished.complete();
      }
    });

    final workId = DateTime.now().microsecondsSinceEpoch;
    const fileName = 'track.mp3';
    final url = 'http://127.0.0.1:${server.port}/track.mp3';
    final manualTask = await service.addTask(
      workId: workId,
      workTitle: 'Work',
      fileName: fileName,
      downloadUrl: url,
      hash: null,
    );
    await requestStarted.future;

    final forceRequest = await service.addTask(
      workId: workId,
      workTitle: 'Work',
      fileName: fileName,
      downloadUrl: url,
      hash: null,
      forceDownload: true,
    );

    expect(forceRequest.id, manualTask.id);
    expect(forceRequest.status, DownloadStatus.downloading);
    expect(requestCount, 1);

    finishResponse.complete();
    await responseFinished.future;
    await _waitForStatus(service, manualTask.id, DownloadStatus.completed);
    expect(requestCount, 1);
  });

  test('force download refreshes a completed task from the network', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requestCount = 0;
    server.listen((request) async {
      requestCount++;
      final bytes = requestCount == 1 ? const [1, 2, 3] : const [7, 8, 9, 10];
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = bytes.length
        ..add(bytes);
      await request.response.close();
    });

    final workId = DateTime.now().microsecondsSinceEpoch;
    const fileName = 'track.mp3';
    final url = 'http://127.0.0.1:${server.port}/track.mp3';
    final hash = 'refresh-$workId';
    final firstTask = await service.addTask(
      workId: workId,
      workTitle: 'Work',
      fileName: fileName,
      downloadUrl: url,
      hash: hash,
      forceDownload: true,
    );
    await _waitForStatus(service, firstTask.id, DownloadStatus.completed);
    final target = File(p.join(downloadRoot.path, '$workId', fileName));
    expect(await target.readAsBytes(), const [1, 2, 3]);

    final refreshedTask = await service.addTask(
      workId: workId,
      workTitle: 'Work',
      fileName: fileName,
      downloadUrl: url,
      hash: hash,
      forceDownload: true,
    );
    await _waitForStatus(service, refreshedTask.id, DownloadStatus.completed);

    expect(requestCount, 2);
    expect(await target.readAsBytes(), const [7, 8, 9, 10]);
  });

  test(
    'cancelling a forced refresh keeps the previous completed file',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final refreshStarted = Completer<void>();
      final finishRefreshResponse = Completer<void>();
      final refreshResponseFinished = Completer<void>();
      var requestCount = 0;
      server.listen((request) async {
        requestCount++;
        if (requestCount == 1) {
          request.response
            ..statusCode = HttpStatus.ok
            ..contentLength = 3
            ..add(const [1, 2, 3]);
          await request.response.close();
          return;
        }

        final response = request.response
          ..bufferOutput = false
          ..statusCode = HttpStatus.ok
          ..contentLength = 6;
        response.add(const [4, 5, 6]);
        await response.flush();
        refreshStarted.complete();
        try {
          await finishRefreshResponse.future;
          response.add(const [7, 8, 9]);
          await response.close();
        } catch (_) {
          // Cancelling the client closes the response while this request waits.
        } finally {
          refreshResponseFinished.complete();
        }
      });

      final workId = DateTime.now().microsecondsSinceEpoch;
      const fileName = 'track.mp3';
      final url = 'http://127.0.0.1:${server.port}/track.mp3';
      final hash = 'cancel-refresh-$workId';
      final task = await service.addTask(
        workId: workId,
        workTitle: 'Work',
        fileName: fileName,
        downloadUrl: url,
        hash: hash,
        forceDownload: true,
      );
      await _waitForStatus(service, task.id, DownloadStatus.completed);
      final target = File(p.join(downloadRoot.path, '$workId', fileName));

      final refresh = await service.addTask(
        workId: workId,
        workTitle: 'Work',
        fileName: fileName,
        downloadUrl: url,
        hash: hash,
        forceDownload: true,
      );
      await refreshStarted.future;
      await service.pauseTask(refresh.id);
      finishRefreshResponse.complete();
      await refreshResponseFinished.future;

      expect(service.taskById(refresh.id)?.status, DownloadStatus.paused);
      expect(await target.readAsBytes(), const [1, 2, 3]);
    },
  );
}

Future<DownloadTask> _waitForStatus(
  DownloadService service,
  String taskId,
  DownloadStatus status,
) {
  DownloadTask? matchingTask() {
    final task = service.taskById(taskId);
    return task?.status == status ? task : null;
  }

  final current = matchingTask();
  if (current != null) return Future.value(current);

  final completed = Completer<DownloadTask>();
  final subscription = service.taskChangesStream.listen((_) {
    final task = matchingTask();
    if (task != null && !completed.isCompleted) completed.complete(task);
  });
  return completed.future
      .timeout(const Duration(seconds: 10))
      .whenComplete(subscription.cancel);
}
