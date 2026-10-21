import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/update_service.dart';

export '../services/update_service.dart' show UpdateInfo, UpdateService;

/// Provider for the update service singleton
final updateServiceProvider = Provider<UpdateService>((ref) {
  return UpdateService();
});

/// Provider for update information
final updateInfoProvider = StateProvider<UpdateInfo?>((ref) => null);

/// Provider to track if red dot should be shown (only when not notified yet)
final showUpdateRedDotProvider = StateProvider<bool>((ref) => false);

/// Provider to track if there's a new version available (regardless of notification status)
final hasNewVersionProvider = StateProvider<bool>((ref) => false);

/// Provider to track if update check is in progress
final isCheckingUpdateProvider = StateProvider<bool>((ref) => false);

/// Status of update download and installation
enum UpdateStatus {
  idle,
  downloading,
  readyToInstall,
  installing,
  failed,
}

/// State of the current update download and installation operation
class UpdateState {
  final UpdateStatus status;
  final double progress; // 0.0 to 1.0
  final int receivedBytes;
  final int totalBytes;
  final String? downloadedFilePath;
  final String? errorMessage;

  const UpdateState({
    this.status = UpdateStatus.idle,
    this.progress = 0.0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.downloadedFilePath,
    this.errorMessage,
  });

  UpdateState copyWith({
    UpdateStatus? status,
    double? progress,
    int? receivedBytes,
    int? totalBytes,
    String? downloadedFilePath,
    String? errorMessage,
  }) {
    return UpdateState(
      status: status ?? this.status,
      progress: progress ?? this.progress,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedFilePath: downloadedFilePath ?? this.downloadedFilePath,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// Controller for downloading and installing app updates
class UpdateController extends StateNotifier<UpdateState> {
  final UpdateService _updateService;
  CancelToken? _cancelToken;

  UpdateController(this._updateService) : super(const UpdateState());

  /// Start downloading the update asset specified in [info].
  Future<void> startDownload(UpdateInfo info) async {
    final downloadUrl = info.downloadUrl;
    if (downloadUrl == null) {
      state = state.copyWith(
        status: UpdateStatus.failed,
        errorMessage: '未找到适用于当前系统的安装包',
      );
      return;
    }

    _cancelToken = CancelToken();
    state = state.copyWith(
      status: UpdateStatus.downloading,
      progress: 0.0,
      receivedBytes: 0,
      totalBytes: info.assetSize ?? 0,
      errorMessage: null,
    );

    try {
      final fileName = info.assetName ?? 'KikoFlu_update';
      final file = await _updateService.downloadUpdate(
        downloadUrl: downloadUrl,
        fileName: fileName,
        cancelToken: _cancelToken,
        onProgress: (received, total) {
          final progress =
              total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
          state = state.copyWith(
            status: UpdateStatus.downloading,
            progress: progress,
            receivedBytes: received,
            totalBytes: total > 0 ? total : (info.assetSize ?? 0),
          );
        },
      );

      state = state.copyWith(
        status: UpdateStatus.readyToInstall,
        progress: 1.0,
        downloadedFilePath: file.path,
      );

      // Automatically trigger installation after download finishes
      await install();
    } catch (e) {
      if (_cancelToken?.isCancelled ?? false) {
        state = const UpdateState(status: UpdateStatus.idle);
      } else {
        state = state.copyWith(
          status: UpdateStatus.failed,
          errorMessage: e.toString(),
        );
      }
    }
  }

  /// Cancel any active download.
  void cancelDownload() {
    _cancelToken?.cancel('User cancelled download');
    state = const UpdateState(status: UpdateStatus.idle);
  }

  /// Launch the installer for the downloaded update.
  Future<bool> install() async {
    final path = state.downloadedFilePath;
    if (path == null) return false;

    state = state.copyWith(status: UpdateStatus.installing);
    final success = await _updateService.installUpdate(path);
    if (!success) {
      state = state.copyWith(
        status: UpdateStatus.readyToInstall,
        errorMessage: '打开安装程序失败',
      );
    }
    return success;
  }

  /// Reset the controller to idle state.
  void reset() {
    _cancelToken?.cancel();
    state = const UpdateState(status: UpdateStatus.idle);
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }
}

/// Provider for update download/install state and actions
final updateControllerProvider =
    StateNotifierProvider<UpdateController, UpdateState>((ref) {
  final updateService = ref.watch(updateServiceProvider);
  return UpdateController(updateService);
});
