import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_sleep_timer_sheet.dart';
import 'package:kikoeru_flutter/src/videos/video_sleep_timer.dart';

void main() {
  testWidgets('finish-current keeps its action active until pause completes', (
    tester,
  ) async {
    final pause = Completer<void>();
    final timer = VideoSleepTimer();
    addTearDown(timer.dispose);
    final owner = Object();
    timer.attach(owner, onPause: () => pause.future, isPlaying: () => true);
    timer.setFinishCurrentVideo(true);
    timer.start(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(timer.handleCompleted(owner), isTrue);
    expect(timer.waitingForCompletion, isFalse);
    expect(timer.actionInProgress, isTrue);
    await tester.pump();
    expect(timer.actionInProgress, isTrue);
    pause.complete();
    await tester.pump();
    expect(timer.actionInProgress, isFalse);
  });

  testWidgets('video timer sheet works in a narrow window with large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final timer = VideoSleepTimer();
    addTearDown(timer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showVideoSleepTimerSheet(context, timer: timer),
              child: const Text('Open timer'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open timer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15 min'));
    await tester.pump();
    expect(timer.isActive, isTrue);
    expect(timer.action, VideoSleepTimerAction.pause);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(timer.isActive, isTrue);
    timer.cancel();
  });

  testWidgets('video timer sheet remains usable in dark landscape', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final timer = VideoSleepTimer();
    addTearDown(timer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: Brightness.dark,
          ),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showVideoSleepTimerSheet(context, timer: timer),
              child: const Text('Open timer'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open timer'));
    await tester.pumpAndSettle();

    final l10n = await S.delegate.load(const Locale('en'));
    final title = find.text(l10n.videoPlayerSleepTimer);
    expect(title, findsOneWidget);
    expect(Theme.of(tester.element(title)).brightness, Brightness.dark);
    final fifteenMinutes = find.text(l10n.videoPlayerTimerMinutes(15));
    await tester.ensureVisible(fifteenMinutes);
    await tester.tap(fifteenMinutes);
    await tester.pumpAndSettle();
    expect(timer.isActive, isTrue);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip(l10n.close));
    await tester.pumpAndSettle();
    expect(timer.isActive, isTrue);
    timer.cancel();
  });

  testWidgets('video timer pauses the active video at the deadline', (
    tester,
  ) async {
    var pauses = 0;
    final timer = VideoSleepTimer(onExit: () async => fail('Unexpected exit'));
    addTearDown(timer.dispose);
    timer.attach(
      Object(),
      onPause: () async => pauses++,
      isPlaying: () => true,
    );
    timer.start(const Duration(minutes: 15));
    await tester.pump(const Duration(minutes: 14));
    expect(pauses, 0);
    await tester.pump(const Duration(minutes: 1));
    expect(pauses, 1);
    expect(timer.isActive, isFalse);
  });

  testWidgets(
    'finish-current timer follows the active video across replacement',
    (tester) async {
      final timer = VideoSleepTimer();
      addTearDown(timer.dispose);
      final first = Object();
      final next = Object();
      var firstPauses = 0;
      var nextPauses = 0;
      timer.attach(
        first,
        onPause: () async => firstPauses++,
        isPlaying: () => true,
      );
      timer.setFinishCurrentVideo(true);
      timer.start(const Duration(minutes: 1));
      timer.attach(
        next,
        onPause: () async => nextPauses++,
        isPlaying: () => true,
      );
      timer.detach(first);
      await tester.pump(const Duration(minutes: 1));
      expect(timer.waitingForCompletion, isTrue);
      expect(timer.handleCompleted(first), isFalse);
      expect(timer.handleCompleted(next), isTrue);
      await tester.pump();
      expect(firstPauses, 0);
      expect(nextPauses, 1);
      expect(timer.isActive, isFalse);
    },
  );

  testWidgets('timer cancellation and explicit exit preserve action order', (
    tester,
  ) async {
    final actions = <String>[];
    final timer = VideoSleepTimer(onExit: () async => actions.add('exit'));
    addTearDown(timer.dispose);
    timer.attach(
      Object(),
      onPause: () async => actions.add('pause'),
      isPlaying: () => false,
    );
    timer.start(const Duration(minutes: 1));
    timer.cancel();
    await tester.pump(const Duration(minutes: 1));
    expect(actions, isEmpty);
    timer.setAction(VideoSleepTimerAction.exit);
    timer.setFinishCurrentVideo(true);
    timer.start(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(actions, ['pause', 'exit']);
  });
}
