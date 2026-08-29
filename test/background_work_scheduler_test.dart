import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/background_work_scheduler.dart';

void main() {
  test('serializes jobs and prioritizes queued user work', () async {
    final scheduler = BackgroundWorkScheduler();
    addTearDown(scheduler.dispose);
    final order = <String>[];
    final releaseFirst = Completer<void>();

    final first = scheduler.schedule<void>(
      key: 'first',
      priority: BackgroundWorkPriority.startup,
      task: () async {
        order.add('first:start');
        await releaseFirst.future;
        order.add('first:end');
      },
    );
    final maintenance = scheduler.schedule<void>(
      key: 'maintenance',
      task: () async => order.add('maintenance'),
    );
    final user = scheduler.schedule<void>(
      key: 'user',
      priority: BackgroundWorkPriority.userInitiated,
      task: () async => order.add('user'),
    );

    releaseFirst.complete();
    await Future.wait([first, maintenance, user]);

    expect(order, ['first:start', 'first:end', 'user', 'maintenance']);
  });

  test('deduplicates jobs with the same key', () async {
    final scheduler = BackgroundWorkScheduler();
    addTearDown(scheduler.dispose);
    var calls = 0;

    Future<int> task() async {
      calls++;
      await Future<void>.delayed(Duration.zero);
      return 7;
    }

    final first = scheduler.schedule<int>(key: 'scan', task: task);
    final second = scheduler.schedule<int>(key: 'scan', task: task);

    expect(await Future.wait([first, second]), [7, 7]);
    expect(calls, 1);
  });
}
