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
    duration: const Duration(milliseconds: 500),
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
  layer.opacity.value,
];

Map<int, double> _opacities(PlayerTrackLayers<int> model) => {
  for (final layer in model.layers) layer.token: layer.opacity.value,
};

void _expectRetainedOpacities(
  PlayerTrackLayers<int> model,
  Map<int, double> before,
) {
  expect(model.layers.map((layer) => layer.token), containsAll(before.keys));
  for (final layer in model.layers) {
    if (before.containsKey(layer.token)) {
      expect(layer.opacity.value, before[layer.token]);
    }
  }
}

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
          await tester.pumpAndSettle();
          expect(model.layers.map((layer) => layer.value), [2]);
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
      await tester.pump(const Duration(milliseconds: 501));
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
          if (kind == PlayerTrackVisualKind.cover) {
            expect(
              model.layers.any((layer) => layer.opacity.value == 1),
              isTrue,
            );
          }
          if (model.pending != null) expect(model.pending, value);
          for (final layer in model.layers.where((layer) => layer.exiting)) {
            // A normal first exit can last 500ms; interruption tightens it.
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
        await tester.pumpAndSettle(const Duration(milliseconds: 30));
        expect(model.pending, isNull);
        expect(model.layers.single.value, 30);
        expect(model.isTransitioning, isFalse);
      },
    );
  }

  testWidgets('cover keeps an opaque base across A-B-C-A retargets', (
    tester,
  ) async {
    final key = GlobalKey<_HostState>();
    await tester.pumpWidget(_Host(key: key, kind: PlayerTrackVisualKind.cover));
    final model = key.currentState!.layers;
    final aToken = model.layers.single.token;

    final beforeB = _opacities(model);
    model.present(1);
    await tester.pump();
    _expectRetainedOpacities(model, beforeB);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      model.layers.any(
        (layer) => layer.token == aToken && layer.opacity.value == 1,
      ),
      isTrue,
    );
    final beforeC = _opacities(model);
    model.present(2);
    await tester.pump();
    _expectRetainedOpacities(model, beforeC);
    expect(model.layers.length, lessThanOrEqualTo(3));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      model.layers.any((layer) => layer.value == 0 && layer.opacity.value == 1),
      isTrue,
    );

    final beforeA = _opacities(model);
    model.present(0);
    await tester.pump();
    _expectRetainedOpacities(model, beforeA);
    expect(model.layers.length, lessThanOrEqualTo(3));
    expect(model.layers.any((layer) => layer.token == aToken), isTrue);
    expect(
      model.layers.any((layer) => layer.value == 0 && layer.opacity.value == 1),
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(model.layers.map((layer) => layer.value), [0]);
    expect(model.layers.single.opacity.value, 1);
  });

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
    expect(_sample(model.layers.single), [0, 0, 1]);
    expect(model.isTransitioning, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
