import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/download_task.dart';

void main() {
  test('download task identity scopes the same hash to its work', () {
    expect(
      DownloadTask.createId(workId: 1, hash: 'same', fileName: 'a.mp3'),
      '1:hash:same',
    );
    expect(
      DownloadTask.createId(workId: 2, hash: 'same', fileName: 'a.mp3'),
      '2:hash:same',
    );
  });

  test('hash-less task identity includes its relative path', () {
    expect(
      DownloadTask.createId(workId: 7, hash: null, fileName: 'disc1/track.mp3'),
      '7:path:disc1/track.mp3',
    );
  });

  test('persisted legacy ids are migrated when decoded', () {
    final task = DownloadTask.fromJson(const {
      'id': 'shared-hash',
      'workId': 42,
      'workTitle': 'Work',
      'fileName': 'track.mp3',
      'downloadUrl': 'https://example.invalid/track.mp3',
      'hash': 'shared-hash',
      'downloadedBytes': 0,
      'status': 'paused',
      'createdAt': '2026-01-01T00:00:00.000',
    });

    expect(task.id, '42:hash:shared-hash');
    expect(task.status, DownloadStatus.paused);
    expect(task.originalDownloadUrl, isNull);
    expect(task.startTimeMs, isNull);
    expect(task.endTimeMs, isNull);
    expect(DownloadTask.fromJson(task.toJson()), task);
  });

  test('chapter interval persists and participates in task equality', () {
    final task = DownloadTask.fromJson(const {
      'id': 'old-chapter-id',
      'workId': -42,
      'workTitle': 'ASMR',
      'fileName': 'track/chapter-2.aac',
      'downloadUrl': 'https://example.invalid/work.m3u8',
      'originalDownloadUrl': 'https://files.example.invalid/chapter',
      'hash': 'chapter-2',
      'downloadedBytes': 31,
      'totalBytes': 100,
      'status': 'paused',
      'createdAt': '2026-01-01T00:00:00.000',
      'startTimeMs': 425000,
      'endTimeMs': 1313000,
    });

    final restored = DownloadTask.fromJson(task.toJson());
    expect(restored.startTimeMs, 425000);
    expect(restored.endTimeMs, 1313000);
    expect(
      restored.originalDownloadUrl,
      'https://files.example.invalid/chapter',
    );
    expect(restored, task);
    expect(task.copyWith(startTimeMs: 900000).startTimeMs, 900000);
    expect(task.copyWith(endTimeMs: 2000000).endTimeMs, 2000000);
    expect(
      task
          .copyWith(originalDownloadUrl: 'https://files.example.invalid/new')
          .originalDownloadUrl,
      'https://files.example.invalid/new',
    );
  });

  test('chapter extension changes keep the persisted hash identity', () {
    final task = DownloadTask(
      id: DownloadTask.createId(
        workId: -42,
        hash: 'chapter-2',
        fileName: 'track/chapter-2.aac',
      ),
      workId: -42,
      workTitle: 'ASMR',
      fileName: 'track/chapter-2.aac',
      downloadUrl: 'https://example.invalid/work.m3u8',
      originalDownloadUrl: 'https://files.example.invalid/chapter',
      hash: 'chapter-2',
      startTimeMs: 425000,
      endTimeMs: 1313000,
      createdAt: DateTime.utc(2026),
    );
    final renamed = task.copyWith(fileName: 'track/chapter-2.flac');
    final restored = DownloadTask.fromJson(renamed.toJson());

    expect(renamed.id, task.id);
    expect(restored.id, task.id);
    expect(restored.fileName, 'track/chapter-2.flac');
    expect(restored.originalDownloadUrl, task.originalDownloadUrl);
  });

  test('final chapter persists without an end time', () {
    final task = DownloadTask(
      id: DownloadTask.createId(
        workId: -1,
        hash: 'final-chapter',
        fileName: 'final.aac',
      ),
      workId: -1,
      workTitle: 'ASMR',
      fileName: 'final.aac',
      downloadUrl: 'https://example.invalid/work.m3u8',
      hash: 'final-chapter',
      startTimeMs: 3956000,
      createdAt: DateTime.utc(2026),
    );

    final restored = DownloadTask.fromJson(task.toJson());
    expect(restored.startTimeMs, 3956000);
    expect(restored.endTimeMs, isNull);
    expect(restored, task);
  });
}
