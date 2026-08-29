import 'dart:async';
import 'dart:collection';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/work.dart';
import '../services/storage_service.dart';
import '../services/speculative_transfer_coordinator.dart';

typedef WorkCoverPrecache = Future<void> Function(
  ImageProvider<Object> provider,
  BuildContext context,
);

int calculateWorkCoverCacheWidth({
  required double viewportWidth,
  required double devicePixelRatio,
  required int crossAxisCount,
  required double horizontalPadding,
  required double crossAxisSpacing,
  bool isListCard = true,
}) {
  if (crossAxisCount <= 1 && isListCard) {
    return (80 * devicePixelRatio).round().clamp(160, 512);
  }

  final columns = crossAxisCount.clamp(1, 6);
  final availableWidth =
      viewportWidth - horizontalPadding * 2 - crossAxisSpacing * (columns - 1);
  final logicalWidth = (availableWidth / columns).clamp(80.0, viewportWidth);
  return (logicalWidth * devicePixelRatio).round().clamp(160, 1024);
}

int resolveWorkCoverCacheWidth(
  BuildContext context, {
  required int crossAxisCount,
  bool isListCard = true,
}) {
  final isLandscape =
      MediaQuery.orientationOf(context) == Orientation.landscape;
  final spacing = isLandscape ? 24.0 : 8.0;
  final padding = isLandscape ? 24.0 : 8.0;

  return calculateWorkCoverCacheWidth(
    viewportWidth: MediaQuery.sizeOf(context).width,
    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    crossAxisCount: crossAxisCount,
    horizontalPadding: padding,
    crossAxisSpacing: spacing,
    isListCard: isListCard,
  );
}

ImageProvider<Object> createWorkCoverImageProvider({
  required Work work,
  required String host,
  required String token,
  int? cacheWidth,
  Map<String, String>? headers,
}) {
  final provider = CachedNetworkImageProvider(
    work.getCoverImageUrl(host, token: token),
    headers: headers ?? StorageService.serverCookieHeaders,
    cacheKey: 'work_cover_${work.id}',
  );
  return ResizeImage.resizeIfNeeded(cacheWidth, null, provider);
}

/// A page-scoped queue for speculative cover decoding.
///
/// Work is deduplicated by server, work id and target decode width. Resetting
/// the controller invalidates queued work when an account or data source
/// changes. Active image decodes are allowed to finish, but their completion is
/// ignored and never starts work from the invalidated generation.
class WorkCoverPrefetchController {
  WorkCoverPrefetchController({
    this.maxConcurrent = 2,
    this.maxPending = 12,
    WorkCoverPrecache? precache,
  })  : assert(maxConcurrent > 0),
        assert(maxPending >= 0),
        _precache = precache ?? _defaultPrecache;

  final int maxConcurrent;
  final int maxPending;
  final WorkCoverPrecache _precache;
  final Queue<_CoverPrefetchTask> _queue = Queue();
  final Map<_CoverPrefetchKey, int> _scheduledKeys = {};
  final List<Completer<void>> _idleWaiters = [];

  int _generation = 0;
  int _activeCount = 0;
  bool _paused = false;
  bool _disposed = false;

  int get activeCount => _activeCount;
  int get pendingCount => _queue.length;
  bool get isPaused => _paused;

  void prefetch(
    BuildContext context,
    Iterable<Work> works, {
    required String host,
    required String token,
    required int crossAxisCount,
    bool isListCard = true,
    Map<String, String>? headers,
  }) {
    if (_disposed || host.isEmpty || !context.mounted) return;

    final targetWidth = resolveWorkCoverCacheWidth(
      context,
      crossAxisCount: crossAxisCount,
      isListCard: isListCard,
    );
    for (final work in works) {
      if (_queue.length >= maxPending) break;
      final key = _CoverPrefetchKey(host, work.id, targetWidth);
      if (_scheduledKeys.containsKey(key)) continue;
      final provider = createWorkCoverImageProvider(
        work: work,
        host: host,
        token: token,
        cacheWidth: targetWidth,
        headers: headers,
      );
      _scheduledKeys[key] = _generation;
      _queue.add(
        _CoverPrefetchTask(
          context: context,
          provider: provider,
          key: key,
          generation: _generation,
        ),
      );
    }
    _pump();
  }

  /// Pauses speculative work without discarding the bounded pending queue.
  void setPaused(bool paused) {
    if (_disposed || _paused == paused) return;
    _paused = paused;
    if (!paused) _pump();
  }

  /// Invalidates work from the previous page/account/data-source generation.
  void cancelPending() {
    if (_disposed) return;
    _generation++;
    _queue.clear();
    _scheduledKeys.clear();
    _completeIdleWaitersIfNeeded();
  }

  Future<void> whenIdle() {
    if (_activeCount == 0 && _queue.isEmpty) return Future.value();
    final completer = Completer<void>();
    _idleWaiters.add(completer);
    return completer.future;
  }

  void dispose() {
    if (_disposed) return;
    cancelPending();
    _disposed = true;
  }

  void _pump() {
    if (_disposed || _paused) return;
    while (_activeCount < maxConcurrent && _queue.isNotEmpty) {
      final task = _queue.removeFirst();
      if (task.generation != _generation || !task.context.mounted) {
        _removeScheduledKey(task);
        continue;
      }
      _activeCount++;
      unawaited(_run(task));
    }
    _completeIdleWaitersIfNeeded();
  }

  Future<void> _run(_CoverPrefetchTask task) async {
    try {
      await _precache(task.provider, task.context);
    } catch (_) {
      // A failed speculative request must not affect normal image loading.
    } finally {
      _activeCount--;
      _removeScheduledKey(task);
      _pump();
    }
  }

  void _removeScheduledKey(_CoverPrefetchTask task) {
    if (_scheduledKeys[task.key] == task.generation) {
      _scheduledKeys.remove(task.key);
    }
  }

  void _completeIdleWaitersIfNeeded() {
    if (_activeCount != 0 || _queue.isNotEmpty || _idleWaiters.isEmpty) return;
    final waiters = List<Completer<void>>.of(_idleWaiters);
    _idleWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  static Future<void> _defaultPrecache(
    ImageProvider<Object> provider,
    BuildContext context,
  ) {
    return precacheImage(provider, context);
  }
}

/// Keeps a cover prefetch controller alive for exactly one page subtree.
class WorkCoverPrefetchScope extends StatefulWidget {
  const WorkCoverPrefetchScope({
    super.key,
    required this.sourceKey,
    required this.builder,
    this.paused = false,
  });

  final Object sourceKey;
  final bool paused;
  final Widget Function(
    BuildContext context,
    WorkCoverPrefetchController controller,
  ) builder;

  @override
  State<WorkCoverPrefetchScope> createState() =>
      _WorkCoverPrefetchScopeState();
}

class _WorkCoverPrefetchScopeState extends State<WorkCoverPrefetchScope> {
  final WorkCoverPrefetchController _controller =
      WorkCoverPrefetchController();
  late final StreamSubscription<bool> _pauseSubscription;
  bool _globallyPaused = false;

  @override
  void initState() {
    super.initState();
    final transferCoordinator = SpeculativeTransferCoordinator.instance;
    _globallyPaused = transferCoordinator.shouldPauseSpeculativeTransfers;
    _applyPauseState();
    _pauseSubscription = transferCoordinator.pauseChanges.listen((paused) {
      _globallyPaused = paused;
      _applyPauseState();
    });
  }

  @override
  void didUpdateWidget(covariant WorkCoverPrefetchScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceKey != widget.sourceKey) {
      _controller.cancelPending();
    }
    _applyPauseState();
  }

  @override
  void dispose() {
    _pauseSubscription.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);

  void _applyPauseState() {
    _controller.setPaused(widget.paused || _globallyPaused);
  }
}

class _CoverPrefetchKey {
  const _CoverPrefetchKey(this.host, this.workId, this.targetWidth);

  final String host;
  final int workId;
  final int targetWidth;

  @override
  bool operator ==(Object other) =>
      other is _CoverPrefetchKey &&
      other.host == host &&
      other.workId == workId &&
      other.targetWidth == targetWidth;

  @override
  int get hashCode => Object.hash(host, workId, targetWidth);
}

class _CoverPrefetchTask {
  const _CoverPrefetchTask({
    required this.context,
    required this.provider,
    required this.key,
    required this.generation,
  });

  final BuildContext context;
  final ImageProvider<Object> provider;
  final _CoverPrefetchKey key;
  final int generation;
}
