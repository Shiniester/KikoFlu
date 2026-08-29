import 'package:flutter/foundation.dart';

import 'download_task.dart';

enum DownloadTaskChangeType { reset, added, updated, removed }

/// Incremental notification emitted by [DownloadService].
@immutable
class DownloadTaskChange {
  const DownloadTaskChange._({
    required this.type,
    this.taskId,
    this.task,
    this.previousTask,
    this.index,
    this.taskIds,
  });

  const DownloadTaskChange.reset(List<String> taskIds)
      : this._(
          type: DownloadTaskChangeType.reset,
          taskIds: taskIds,
        );

  DownloadTaskChange.added(DownloadTask task, int index)
      : this._(
          type: DownloadTaskChangeType.added,
          taskId: task.id,
          task: task,
          index: index,
        );

  DownloadTaskChange.updated({
    required DownloadTask task,
    required DownloadTask previousTask,
    required int index,
  }) : this._(
          type: DownloadTaskChangeType.updated,
          taskId: task.id,
          task: task,
          previousTask: previousTask,
          index: index,
        );

  DownloadTaskChange.removed(DownloadTask task, int index)
      : this._(
          type: DownloadTaskChangeType.removed,
          taskId: task.id,
          previousTask: task,
          index: index,
        );

  final DownloadTaskChangeType type;
  final String? taskId;
  final DownloadTask? task;
  final DownloadTask? previousTask;
  final int? index;
  final List<String>? taskIds;

  bool get isStructural => type != DownloadTaskChangeType.updated;

  bool get affectsSummary =>
      isStructural || previousTask?.status != task?.status;
}

@immutable
class DownloadTaskSummary {
  const DownloadTaskSummary({
    required this.total,
    required this.active,
    required this.pending,
    required this.paused,
    required this.completed,
    required this.failed,
  });

  const DownloadTaskSummary.empty()
      : total = 0,
        active = 0,
        pending = 0,
        paused = 0,
        completed = 0,
        failed = 0;

  factory DownloadTaskSummary.fromTasks(Iterable<DownloadTask> tasks) {
    var total = 0;
    var downloading = 0;
    var pending = 0;
    var paused = 0;
    var completed = 0;
    var failed = 0;
    for (final task in tasks) {
      total++;
      switch (task.status) {
        case DownloadStatus.downloading:
          downloading++;
        case DownloadStatus.pending:
          pending++;
        case DownloadStatus.paused:
          paused++;
        case DownloadStatus.completed:
          completed++;
        case DownloadStatus.failed:
          failed++;
      }
    }
    return DownloadTaskSummary(
      total: total,
      active: downloading + pending,
      pending: pending,
      paused: paused,
      completed: completed,
      failed: failed,
    );
  }

  final int total;
  final int active;
  final int pending;
  final int paused;
  final int completed;
  final int failed;

  @override
  bool operator ==(Object other) =>
      other is DownloadTaskSummary &&
      other.total == total &&
      other.active == active &&
      other.pending == pending &&
      other.paused == paused &&
      other.completed == completed &&
      other.failed == failed;

  @override
  int get hashCode =>
      Object.hash(total, active, pending, paused, completed, failed);
}

abstract interface class DownloadTaskRepository {
  List<DownloadTask> get tasks;
  List<String> get taskIds;
  DownloadTaskSummary get summary;
  Stream<DownloadTaskChange> get taskChangesStream;
  DownloadTask? taskById(String taskId);
}
