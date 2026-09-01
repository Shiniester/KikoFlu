import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/download_task.dart';
import '../models/download_task_change.dart';
import '../services/download_service.dart';

final downloadServiceProvider = Provider<DownloadTaskRepository>(
  (ref) => DownloadService.instance,
);

/// Stable task ordering. Progress-only changes do not emit a new list; status
/// transitions do so category-based screens can move a task immediately.
final downloadTaskIdsProvider = StreamProvider<List<String>>((ref) async* {
  final service = ref.watch(downloadServiceProvider);
  yield service.taskIds;
  await for (final change in service.taskChangesStream) {
    if (change.isStructural ||
        change.previousTask?.status != change.task?.status) {
      yield service.taskIds;
    }
  }
});

/// Tasks shown by the active-download page. The list changes only when an id
/// is added/removed or a task crosses the completed boundary.
final activeDownloadTaskIdsProvider = StreamProvider<List<String>>((ref) async* {
  final service = ref.watch(downloadServiceProvider);

  List<String> activeIds() => service.tasks
      .where((task) => task.status != DownloadStatus.completed)
      .map((task) => task.id)
      .toList(growable: false);

  yield activeIds();
  await for (final change in service.taskChangesStream) {
    if (change.isStructural ||
        change.previousTask?.status != change.task?.status) {
      yield activeIds();
    }
  }
});

/// A row-level provider: a progress event wakes only the matching task row.
final downloadTaskProvider =
    StreamProvider.family<DownloadTask?, String>((ref, taskId) async* {
  final service = ref.watch(downloadServiceProvider);
  yield service.taskById(taskId);
  await for (final change in service.taskChangesStream) {
    if (change.type == DownloadTaskChangeType.reset ||
        change.taskId == taskId) {
      yield service.taskById(taskId);
    }
  }
});

final downloadSummaryProvider =
    StreamProvider<DownloadTaskSummary>((ref) async* {
  final service = ref.watch(downloadServiceProvider);
  var previous = service.summary;
  yield previous;
  await for (final change in service.taskChangesStream) {
    if (!change.affectsSummary) continue;
    final next = service.summary;
    if (next != previous) {
      previous = next;
      yield next;
    }
  }
});

typedef DownloadTaskWidgetBuilder = Widget Function(
  BuildContext context,
  DownloadTask task,
);

/// Reusable row-level subscription boundary for download lists.
class DownloadTaskConsumer extends ConsumerWidget {
  const DownloadTaskConsumer({
    super.key,
    required this.taskId,
    required this.builder,
    this.missing = const SizedBox.shrink(),
    this.debugOnBuild,
  });

  final String taskId;
  final DownloadTaskWidgetBuilder builder;
  final Widget missing;
  final VoidCallback? debugOnBuild;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(downloadServiceProvider);
    final task = ref.watch(downloadTaskProvider(taskId)).valueOrNull ??
        repository.taskById(taskId);
    if (task == null) return missing;
    debugOnBuild?.call();
    return builder(context, task);
  }
}
