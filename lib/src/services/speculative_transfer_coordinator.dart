import 'dart:async';

/// Coordinates bandwidth-sensitive speculative work across the app.
class SpeculativeTransferCoordinator {
  SpeculativeTransferCoordinator._();

  static final SpeculativeTransferCoordinator instance =
      SpeculativeTransferCoordinator._();

  final StreamController<bool> _pauseController =
      StreamController<bool>.broadcast(sync: true);

  int _activeUserDownloads = 0;
  int _downloadCapacity = 1;
  bool _playerBuffering = false;
  bool _lastPauseValue = false;

  bool get shouldPauseSpeculativeTransfers =>
      _playerBuffering || _activeUserDownloads >= _downloadCapacity;

  Stream<bool> get pauseChanges => _pauseController.stream;

  void updateUserDownloads({required int active, required int capacity}) {
    _activeUserDownloads = active < 0 ? 0 : active;
    _downloadCapacity = capacity <= 0 ? 1 : capacity;
    _emitIfChanged();
  }

  void setPlayerBuffering(bool buffering) {
    _playerBuffering = buffering;
    _emitIfChanged();
  }

  void _emitIfChanged() {
    final next = shouldPauseSpeculativeTransfers;
    if (next == _lastPauseValue) return;
    _lastPauseValue = next;
    _pauseController.add(next);
  }

  void resetForTest() {
    _activeUserDownloads = 0;
    _downloadCapacity = 1;
    _playerBuffering = false;
    _emitIfChanged();
  }
}
