import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail_route_readiness.dart';

class _ReadinessProbe extends StatefulWidget {
  const _ReadinessProbe({required this.readiness, super.key});

  final WorkDetailRouteReadiness readiness;

  @override
  State<_ReadinessProbe> createState() => _ReadinessProbeState();
}

class _ReadinessProbeState extends State<_ReadinessProbe> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.readiness.bind(
      route: ModalRoute.of(context),
      navigator: Navigator.maybeOf(context),
    );
  }

  @override
  void dispose() {
    widget.readiness.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('Detail'));
}

void main() {
  testWidgets('waits for entry animation and its final painted frame', (
    tester,
  ) async {
    final readiness = WorkDetailRouteReadiness();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Home')),
      ),
    );
    final route = MaterialPageRoute<void>(
      builder: (_) => _ReadinessProbe(readiness: readiness),
    );
    navigator.currentState!.push(route);
    await tester.pump();

    var finalFramePainted = false;
    var readyBeforeFinalPaint = false;
    route.animation!.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          finalFramePainted = true;
        });
      }
    });

    var result = false;
    var completed = false;
    final wait = readiness.waitForIdle().then((value) {
      result = value;
      readyBeforeFinalPaint = value && !finalFramePainted;
      completed = true;
    });
    const alreadyPumped = Duration(milliseconds: 100);
    await tester.pump(alreadyPumped);
    expect(completed, isFalse);
    expect(route.animation!.status, AnimationStatus.forward);
    await tester.pump(route.transitionDuration - alreadyPumped);
    await tester.pumpAndSettle();
    expect(route.animation!.status, AnimationStatus.completed);
    if (!completed) await tester.pump();
    await wait;

    expect(result, isTrue);
    expect(finalFramePainted, isTrue);
    expect(readyBeforeFinalPaint, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('waits through a covering dialog and resumes after it closes', (
    tester,
  ) async {
    final readiness = WorkDetailRouteReadiness();
    final navigator = GlobalKey<NavigatorState>();
    final probeKey = GlobalKey<_ReadinessProbeState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Home')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => _ReadinessProbe(key: probeKey, readiness: readiness),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump();

    navigator.currentState!.push<void>(
      DialogRoute<void>(
        context: probeKey.currentContext!,
        builder: (_) => const AlertDialog(content: Text('Covered')),
      ),
    );
    await tester.pumpAndSettle();
    var completed = false;
    final wait = readiness.waitForIdle().then((_) => completed = true);
    await tester.pump();
    expect(completed, isFalse);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pump();
    await wait;
    expect(completed, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('gesture cancellation restores readiness without another route', (
    tester,
  ) async {
    final readiness = WorkDetailRouteReadiness();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Home')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => _ReadinessProbe(readiness: readiness),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump();

    final gestureState = navigator.currentState!.userGestureInProgressNotifier;
    gestureState.value = true;
    var result = false;
    var completed = false;
    final wait = readiness.waitForIdle().then((value) {
      result = value;
      completed = true;
    });
    await tester.pump();
    expect(completed, isFalse);

    gestureState.value = false;
    await tester.pump();
    await wait;
    expect(result, isTrue);
    expect(find.text('Detail'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('popping or disposing releases a pending wait as false', (
    tester,
  ) async {
    final readiness = WorkDetailRouteReadiness();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Home')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => _ReadinessProbe(readiness: readiness),
      ),
    );
    await tester.pump();
    navigator.currentState!.userGestureInProgressNotifier.value = true;
    final wait = readiness.waitForIdle();
    navigator.currentState!.pop();
    await tester.pump();

    expect(await wait, isFalse);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing releases a wait blocked by an active gesture', (
    tester,
  ) async {
    final readiness = WorkDetailRouteReadiness();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Home')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => _ReadinessProbe(readiness: readiness),
      ),
    );
    await tester.pump();
    navigator.currentState!.userGestureInProgressNotifier.value = true;
    final wait = readiness.waitForIdle();
    readiness.dispose();

    expect(await wait, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
