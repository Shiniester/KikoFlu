import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/download_task.dart';
import 'package:kikoeru_flutter/src/services/download_task_persistence.dart';

void main() {
  test('large task JSON round-trips through the isolate codec', () async {
    final tasks = List.generate(
      1000,
      (index) => DownloadTask(
        id: DownloadTask.createId(
          workId: index ~/ 4,
          hash: null,
          fileName: 'folder/$index.mp3',
        ),
        workId: index ~/ 4,
        workTitle: 'Work ${index ~/ 4}',
        fileName: 'folder/$index.mp3',
        downloadUrl: 'https://example.com/$index.mp3',
        downloadedBytes: index * 10,
        totalBytes: 100000,
        status: index.isEven
            ? DownloadStatus.downloading
            : DownloadStatus.paused,
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );

    final encoded = await DownloadTaskPersistence.encode(
      tasks,
      isolateTaskThreshold: 0,
    );
    final decodedMaps = await DownloadTaskPersistence.decode(
      encoded,
      isolateDecodeThresholdBytes: 0,
    );
    final decoded = decodedMaps.map(DownloadTask.fromJson).toList();

    expect(decoded, hasLength(tasks.length));
    expect(decoded.first.toJson(), tasks.first.toJson());
    expect(decoded.last.toJson(), tasks.last.toJson());
  });
}
