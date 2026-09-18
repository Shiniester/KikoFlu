import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_track_layers.dart';

class _Host extends StatefulWidget {
  const _Host({super.key, required this.kind});
  final PlayerTrackVisualKind kind;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  late final layers = PlayerTrackLayers<int>(
    vsync: this,
    initialValue: 0,
    sameContent: (a, b) => a == b,
    kind: widget.kind,
    duration: const Duration(milliseconds: 300),
  );
  @override
  void dispose() {
    layers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

List<double> _sample(PlayerTrackLayer<int> layer) => [
  layer.offset.value.dx,
  layer.offset.value.dy,
  layer.scale.value,
  layer.opacity.value,
];

void main() {
  for (final kind in PlayerTrackVisualKind.values) {
    for (final interruption in [45, 180]) {
      testWidgets(
        '$kind retargets at ${interruption}ms without resetting layers',
        (tester) async {
          final key = GlobalKey<_HostState>();
          await tester.pumpWidget(_Host(key: key, kind: kind));
          final model = key.currentState!.layers;
          model.present(1);
          await tester.pump();
          await tester.pump(Duration(milliseconds: interruption));
          final retained = model.layers.toList();
          final values = retained.map(_sample).toList();
          model.present(2, direction: -1);
          await tester.pump();
          for (var i = 0; i < retained.length; i++) {
            expect(_sample(retained[i]), values[i]);
          }
          await tester.pump(const Duration(milliseconds: 126));
          expect(model.layers.map((layer) => layer.value), [2]);
          await tester.pump(const Duration(milliseconds: 300));
          expect(model.isTransitioning, isFalse);
          await tester.pumpWidget(const SizedBox());
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('$kind reuses a visible target without changing paint order', (
      tester,
    ) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(_Host(key: key, kind: kind));
      final model = key.currentState!.layers;
      model.present(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 45));
      final tokens = model.layers.map((layer) => layer.token).toList();
      final values = model.layers.map(_sample).toList();
      model.present(0, direction: -1);
      await tester.pump();
      expect(model.layers.map((layer) => layer.token), tokens);
      expect(model.layers.map(_sample), values);
      await tester.pump(const Duration(milliseconds: 301));
      expect(model.layers.single.value, 0);
    });

    testWidgets(
      '$kind stays bounded under requests every 30ms and settles latest',
      (tester) async {
        final key = GlobalKey<_HostState>();
        await tester.pumpWidget(_Host(key: key, kind: kind));
        final model = key.currentState!.layers;
        final deadlines = <int, int>{};
        var clock = 0;
        for (var value = 1; value <= 30; value++) {
          model.present(value, direction: value.isEven ? -1 : 1);
          await tester.pump();
          expect(model.layers.length, inInclusiveRange(1, 3));
          if (model.pending != null) expect(model.pending, value);
          for (final layer in model.layers.where((layer) => layer.exiting)) {
            // A normal first exit can last 300ms; interruption tightens it.
            final remaining =
                (layer.controller.duration!.inMilliseconds *
                        (1 - layer.controller.value))
                    .ceil();
            final deadline = clock + remaining;
            if (deadlines.containsKey(layer.token)) {
              expect(deadline, lessThanOrEqualTo(deadlines[layer.token]! + 1));
            }
            deadlines[layer.token] = deadline;
          }
          await tester.pump(const Duration(milliseconds: 30));
          clock += 30;
        }
        await tester.pump(const Duration(milliseconds: 130));
        await tester.pump(const Duration(milliseconds: 310));
        expect(model.pending, isNull);
        expect(model.layers.single.value, 30);
        expect(model.isTransitioning, isFalse);
      },
    );
  }

  testWidgets('discarding queued artwork while loading keeps a visible layer', (
    tester,
  ) async {
    final key = GlobalKey<_HostState>();
    await tester.pumpWidget(_Host(key: key, kind: PlayerTrackVisualKind.cover));
    final model = key.currentState!.layers;
    for (var value = 1; value <= 3; value++) {
      model.present(value);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(model.pending, 3);
    model.discardPending();
    await tester.pump(const Duration(milliseconds: 500));
    expect(model.layers.single.value, 2);
    model.present(4);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    model.showImmediately(5);
    expect(model.layers.single.value, 5);
    expect(_sample(model.layers.single), [0, 0, 1, 1]);
    expect(model.isTransitioning, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
