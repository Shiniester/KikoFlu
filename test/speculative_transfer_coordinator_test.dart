import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/speculative_transfer_coordinator.dart';

void main() {
  final coordinator = SpeculativeTransferCoordinator.instance;

  tearDown(coordinator.resetForTest);

  test('pauses speculative transfers for buffering or a full download pool',
      () {
    coordinator.updateUserDownloads(active: 2, capacity: 3);
    expect(coordinator.shouldPauseSpeculativeTransfers, isFalse);

    coordinator.updateUserDownloads(active: 3, capacity: 3);
    expect(coordinator.shouldPauseSpeculativeTransfers, isTrue);

    coordinator.updateUserDownloads(active: 0, capacity: 3);
    expect(coordinator.shouldPauseSpeculativeTransfers, isFalse);

    coordinator.setPlayerBuffering(true);
    expect(coordinator.shouldPauseSpeculativeTransfers, isTrue);
  });
}
