import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/work.dart';
import '../models/history_record.dart';
import '../models/audio_track.dart';
import '../services/history_database.dart';
import '../services/audio_player_service.dart' as import_service;
import '../services/log_service.dart';
import '../services/playback_history_service.dart';
import '../utils/paged_collection.dart';

class HistoryState {
  final List<HistoryRecord> records;
  final bool isLoading;
  final int currentPage;
  final int totalCount;
  final int pageSize;
  final bool hasMore;
  final bool isRefreshing;
  final bool isLoadingMore;
  final String? error;
  final String? loadMoreError;

  const HistoryState({
    this.records = const [],
    this.isLoading = false,
    this.currentPage = 1,
    this.totalCount = 0,
    this.pageSize = 20,
    this.hasMore = true,
    this.isRefreshing = false,
    this.isLoadingMore = false,
    this.error,
    this.loadMoreError,
  });

  HistoryState copyWith({
    List<HistoryRecord>? records,
    bool? isLoading,
    int? currentPage,
    int? totalCount,
    int? pageSize,
    bool? hasMore,
    bool? isRefreshing,
    bool? isLoadingMore,
    String? error,
    String? loadMoreError,
  }) {
    return HistoryState(
      records: records ?? this.records,
      isLoading: isLoading ?? this.isLoading,
      currentPage: currentPage ?? this.currentPage,
      totalCount: totalCount ?? this.totalCount,
      pageSize: pageSize ?? this.pageSize,
      hasMore: hasMore ?? this.hasMore,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: error,
      loadMoreError: loadMoreError,
    );
  }
}

final historyProvider = StateNotifierProvider<HistoryNotifier, HistoryState>((
  ref,
) {
  return HistoryNotifier(ref);
});

class HistoryNotifier extends StateNotifier<HistoryState> {
  // ignore: unused_field - kept for potential future use with Ref
  final Ref _ref;
  HistoryNotifier(this._ref) : super(const HistoryState()) {
    load(refresh: true);
    _initHistoryUpdateListener();
  }

  StreamSubscription? _historyUpdateSubscription;
  final PagedRequestGate _requestGate = PagedRequestGate();
  bool _isBrowsing = false;
  bool _refreshWhenNextVisible = false;
  bool _hasSnapshot = false;
  List<HistoryRecord> _sessionRecords = const [];

  /// Tracks the history browsing session, including covered and paused states.
  void setVisible(bool visible) {
    if (_isBrowsing == visible) return;
    _isBrowsing = visible;
    if (visible) {
      if (_refreshWhenNextVisible) {
        _refreshWhenNextVisible = false;
        unawaited(refresh());
      }
    } else {
      _refreshWhenNextVisible = true;
    }
  }

  Future<void> load({
    bool refresh = false,
    bool force = false,
    int? targetPage,
  }) async {
    final token = _requestGate.begin(supersede: force || refresh);
    if (token == null) return;

    final page = refresh || !_hasSnapshot
        ? 1
        : (targetPage ?? state.currentPage);

    state = state.copyWith(
      isLoading: true,
      isRefreshing: false,
      isLoadingMore: false,
      error: null,
      loadMoreError: null,
      currentPage: page,
    );

    try {
      if (refresh || !_hasSnapshot) {
        final records = await HistoryDatabase.instance.getAllHistory();
        if (!_requestGate.isCurrent(token)) return;
        _sessionRecords = List.unmodifiable(records);
        _hasSnapshot = true;
      }
      if (!_requestGate.isCurrent(token)) return;

      _showPage(page);
    } catch (e) {
      if (!_requestGate.isCurrent(token)) return;
      final message = e.toString();
      state = state.copyWith(
        isLoading: false,
        isRefreshing: false,
        isLoadingMore: false,
        error: message,
        loadMoreError: null,
      );
      logOutput('Failed to load history: $e');
    } finally {
      _requestGate.complete(token);
    }
  }

  Future<void> refresh() async {
    _refreshWhenNextVisible = false;
    await load(refresh: true, force: true);
  }

  void _showPage(int requestedPage) {
    final totalCount = _sessionRecords.length;
    final lastPage = totalCount == 0
        ? 1
        : (totalCount - 1) ~/ state.pageSize + 1;
    final page = requestedPage < 1
        ? 1
        : requestedPage > lastPage
        ? lastPage
        : requestedPage;
    final start = (page - 1) * state.pageSize;
    final end = start + state.pageSize < totalCount
        ? start + state.pageSize
        : totalCount;

    state = state.copyWith(
      records: List.unmodifiable(_sessionRecords.getRange(start, end)),
      currentPage: page,
      totalCount: totalCount,
      hasMore: end < totalCount,
      isLoading: false,
      isRefreshing: false,
      isLoadingMore: false,
      error: null,
      loadMoreError: null,
    );
  }

  Future<void> loadMore() async {
    if (!state.hasMore || state.isRefreshing) return;
    await load(targetPage: state.currentPage + 1);
  }

  Future<void> nextPage() => loadMore();

  Future<void> previousPage() async {
    if (state.currentPage <= 1 || state.isLoading) return;
    await load(targetPage: state.currentPage - 1);
  }

  Future<void> goToPage(int page) async {
    if (page < 1 || page == state.currentPage || state.isLoading) return;
    await load(targetPage: page);
  }

  /// 外部直接写入历史（例如 history_work_card 恢复播放时）
  Future<void> addOrUpdate(
    Work work, {
    AudioTrack? track,
    int? positionMs,
  }) async {
    final now = DateTime.now();
    final audioService = PlaybackHistoryService.instance;

    int playlistIndex = 0;
    int playlistTotal = 0;

    // 尝试从播放历史服务获取播放列表信息
    if (audioService.currentWorkId == work.id) {
      playlistIndex = audioService.currentTrack != null
          ? AudioPlayerServiceHelper.currentIndex
          : 0;
      playlistTotal = AudioPlayerServiceHelper.queueLength;
    }

    final existing = await HistoryDatabase.instance.getHistoryByWorkId(work.id);
    HistoryRecord record;

    if (existing != null) {
      record = existing.copyWith(
        work: work,
        lastPlayedTime: now,
        lastTrack: track ?? existing.lastTrack,
        lastPositionMs: positionMs ?? existing.lastPositionMs,
        playlistIndex: playlistIndex > 0
            ? playlistIndex
            : existing.playlistIndex,
        playlistTotal: playlistTotal > 0
            ? playlistTotal
            : existing.playlistTotal,
      );
    } else {
      record = HistoryRecord(
        work: work,
        lastPlayedTime: now,
        lastTrack: track,
        lastPositionMs: positionMs ?? 0,
        playlistIndex: playlistIndex,
        playlistTotal: playlistTotal,
      );
    }

    await HistoryDatabase.instance.addOrUpdate(record);
    _refreshWhenNextVisible = true;
  }

  Future<void> remove(int workId) async {
    await HistoryDatabase.instance.delete(workId);
    _requestGate.invalidate();
    _refreshWhenNextVisible = true;
    if (!_hasSnapshot) {
      await refresh();
      return;
    }

    _sessionRecords = List.unmodifiable(
      _sessionRecords.where((record) => record.work.id != workId),
    );
    _showPage(state.currentPage);
  }

  Future<void> clear() async {
    await HistoryDatabase.instance.clear();
    _requestGate.invalidate();
    _refreshWhenNextVisible = false;
    _sessionRecords = const [];
    _hasSnapshot = true;
    state = state.copyWith(
      records: [],
      totalCount: 0,
      currentPage: 1,
      hasMore: false,
      isLoading: false,
      isRefreshing: false,
      isLoadingMore: false,
      error: null,
      loadMoreError: null,
    );
  }

  /// 监听播放服务写入，供下次进入历史页时刷新快照。
  void _initHistoryUpdateListener() {
    _historyUpdateSubscription = PlaybackHistoryService
        .instance
        .historyUpdatedStream
        .listen((_) => _refreshWhenNextVisible = true);
  }

  @override
  void dispose() {
    _historyUpdateSubscription?.cancel();
    super.dispose();
  }
}

/// 帮助类，用于从 AudioPlayerService 获取播放列表信息
/// 避免直接在 provider 层级依赖 AudioPlayerService 的内部状态
class AudioPlayerServiceHelper {
  static int get currentIndex {
    try {
      return _audioPlayerService.currentIndex;
    } catch (_) {
      return 0;
    }
  }

  static int get queueLength {
    try {
      return _audioPlayerService.queue.length;
    } catch (_) {
      return 0;
    }
  }

  static import_service.AudioPlayerService get _audioPlayerService =>
      import_service.AudioPlayerService.instance;
}
