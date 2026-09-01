import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/download_task.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';

void main() {
  testWidgets('a progress event rebuilds only its matching task row',
      (tester) async {
    final repository = _FakeDownloadTaskRepository([
      _task('a'),
      _task('b'),
    ]);
    addTearDown(repository.dispose);
    final builds = <String, int>{'a': 0, 'b': 0};

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadServiceProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          home: Column(
            children: [
              for (final id in const ['a', 'b'])
                DownloadTaskConsumer(
                  taskId: id,
                  debugOnBuild: () => builds[id] = builds[id]! + 1,
                  builder: (context, task) => Text(
                    '$id:${task.downloadedBytes}',
                    key: ValueKey('row-$id'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final beforeA = builds['a']!;
    final beforeB = builds['b']!;

    repository.update(_task('a').copyWith(downloadedBytes: 250));
    await tester.pump();

    expect(find.text('a:250'), findsOneWidget);
    expect(builds['a'], greaterThan(beforeA));
    expect(builds['b'], beforeB);
  });

  test('download summary counts every status without changing JSON tasks', () {
    final summary = DownloadTaskSummary.fromTasks([
      _task('downloading', status: DownloadStatus.downloading),
      _task('pending', status: DownloadStatus.pending),
      _task('paused', status: DownloadStatus.paused),
      _task('completed', status: DownloadStatus.completed),
      _task('failed', status: DownloadStatus.failed),
    ]);

    expect(summary.total, 5);
    expect(summary.active, 2);
    expect(summary.pending, 1);
    expect(summary.paused, 1);
    expect(summary.completed, 1);
    expect(summary.failed, 1);
  });
}

DownloadTask _task(
  String id, {
  DownloadStatus status = DownloadStatus.downloading,
}) {
  return DownloadTask(
    id: id,
    workId: id.hashCode,
    workTitle: 'Work $id',
    fileName: '$id.mp3',
    downloadUrl: 'https://example.com/$id.mp3',
    status: status,
    totalBytes: 1000,
    createdAt: DateTime(2026),
  );
}

class _FakeDownloadTaskRepository implements DownloadTaskRepository {
  _FakeDownloadTaskRepository(Iterable<DownloadTask> tasks)
      : _tasks = List.of(tasks);

  final List<DownloadTask> _tasks;
  final StreamController<DownloadTaskChange> _changes =
      StreamController.broadcast(sync: true);

  @override
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  @override
  List<String> get taskIds =>
      List.unmodifiable(_tasks.map((task) => task.id));

  @override
  DownloadTaskSummary get summary => DownloadTaskSummary.fromTasks(_tasks);

  @override
  Stream<DownloadTaskChange> get taskChangesStream => _changes.stream;

  @override
  DownloadTask? taskById(String taskId) {
    for (final task in _tasks) {
      if (task.id == taskId) return task;
    }
    return null;
  }

  void update(DownloadTask task) {
    final index = _tasks.indexWhere((candidate) => candidate.id == task.id);
    final previous = _tasks[index];
    _tasks[index] = task;
    _changes.add(
      DownloadTaskChange.updated(
        task: task,
        previousTask: previous,
        index: index,
      ),
    );
  }

  void dispose() => _changes.close();
}
