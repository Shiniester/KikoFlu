import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';

void main() {
  testWidgets('automatic detail replacement retains the original return step', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final disposed = <int>[];
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                pushWorkDetailRoute(
                  context,
                  builder: (_) => _Detail(index: 0, disposed: disposed),
                ).then((_) => returned = true),
              ),
              child: const Text('Open detail'),
            ),
          ),
          bottomNavigationBar: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: 64, child: Center(child: Text('Audio'))),
              SizedBox(height: 58, child: Center(child: Text('Tabs'))),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open detail'));
    await tester.pumpAndSettle();
    for (var index = 0; index < 2; index++) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Detail ${index + 1}'), findsOneWidget);
      expect(disposed, contains(index));
      expect(returned, isFalse);
      expect(tester.takeException(), isNull);
    }
    Navigator.of(tester.element(find.text('Detail 2'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(returned, isFalse);
    await tester.pumpAndSettle();
    expect(find.text('Open detail'), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('Tabs'), findsOneWidget);
    expect(disposed, containsAll([0, 1, 2]));
    expect(returned, isTrue);
    expect(tester.takeException(), isNull);
  });
}

class _Detail extends StatefulWidget {
  const _Detail({required this.index, required this.disposed});
  final int index;
  final List<int> disposed;

  @override
  State<_Detail> createState() => _DetailState();
}

class _DetailState extends State<_Detail> {
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Builder(
      builder: (context) => Column(
        children: [
          Text('Detail ${widget.index}'),
          TextButton(
            onPressed: () => unawaited(
              replaceWorkDetailRoute(
                context,
                builder: (_) =>
                    _Detail(index: widget.index + 1, disposed: widget.disposed),
              ),
            ),
            child: const Text('Next'),
          ),
        ],
      ),
    ),
    bottomNavigationBar: const SizedBox(
      height: 64,
      child: Center(child: Text('Audio')),
    ),
  );

  @override
  void dispose() {
    widget.disposed.add(widget.index);
    super.dispose();
  }
}
