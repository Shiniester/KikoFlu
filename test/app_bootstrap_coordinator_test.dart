import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/app_bootstrap_coordinator.dart';
import 'package:kikoeru_flutter/src/services/background_work_scheduler.dart';
import 'package:kikoeru_flutter/src/widgets/app_bootstrap_gate.dart';

void main() {
  test('critical bootstrap exposes failure and can retry', () async {
    var attempts = 0;
    final coordinator = AppBootstrapCoordinator(
      initializeCritical: () async {
        attempts++;
        if (attempts == 1) throw StateError('first attempt');
      },
      scheduler: BackgroundWorkScheduler(),
    );
    addTearDown(coordinator.dispose);

    await coordinator.start();
    expect(coordinator.state.phase, BootstrapPhase.failed);
    expect(coordinator.state.error, isA<StateError>());

    await coordinator.retry();
    expect(coordinator.state.phase, BootstrapPhase.ready);
    expect(attempts, 2);
  });

  testWidgets('gate renders app before starting deferred work', (tester) async {
    final critical = Completer<void>();
    final deferred = Completer<void>();
    var deferredStarted = false;
    final scheduler = BackgroundWorkScheduler();
    final coordinator = AppBootstrapCoordinator(
      initializeCritical: () => critical.future,
      scheduler: scheduler,
      deferredTasks: [
        DeferredBootstrapTask(
          key: 'deferred',
          run: () async {
            deferredStarted = true;
            await deferred.future;
          },
        ),
      ],
    );

    await tester.pumpWidget(
      AppBootstrapGate(
        coordinator: coordinator,
        readyBuilder: (_) => const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('ready'),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(deferredStarted, isFalse);

    critical.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);

    await tester.pump();
    expect(deferredStarted, isTrue);
    deferred.complete();
    await tester.pump();
  });

  testWidgets('prestarted gate renders ready tree on its first frame', (
    tester,
  ) async {
    var deferredRuns = 0;
    final coordinator = AppBootstrapCoordinator(
      initializeCritical: () async {},
      scheduler: BackgroundWorkScheduler(),
      deferredTasks: [
        DeferredBootstrapTask(
          key: 'deferred-prestarted',
          run: () async => deferredRuns++,
        ),
      ],
    );
    await coordinator.start();

    await tester.pumpWidget(
      AppBootstrapGate(
        coordinator: coordinator,
        readyBuilder: (_) => const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('ready-first-frame'),
        ),
      ),
    );

    expect(find.text('ready-first-frame'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump();
    expect(deferredRuns, 1);
  });
}
