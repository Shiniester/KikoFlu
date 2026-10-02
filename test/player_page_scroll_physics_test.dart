import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_page_scroll_physics.dart';

void main() {
  test(
    'page snap keeps release position and velocity while settling faster',
    () {
      const basePhysics = PageScrollPhysics(parent: ClampingScrollPhysics());
      const fasterPhysics = PageScrollPhysics(
        parent: PlayerPageScrollPhysics(parent: ClampingScrollPhysics()),
      );
      final metrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1200,
        pixels: 120,
        viewportDimension: 400,
        axisDirection: AxisDirection.right,
        devicePixelRatio: 1,
      );

      final baseSpring = basePhysics.spring;
      final fasterSpring = fasterPhysics.spring;
      expect(fasterSpring.mass, baseSpring.mass);
      expect(
        fasterSpring.stiffness / baseSpring.stiffness,
        closeTo(
          1 / (playerPageScrollTimeScale * playerPageScrollTimeScale),
          1e-6,
        ),
      );
      expect(
        fasterSpring.damping / baseSpring.damping,
        closeTo(1 / playerPageScrollTimeScale, 1e-6),
      );

      final baseSimulation = basePhysics.createBallisticSimulation(
        metrics,
        1000,
      )!;
      final fasterSimulation = fasterPhysics.createBallisticSimulation(
        metrics,
        1000,
      )!;

      expect(fasterSimulation.x(0), baseSimulation.x(0));
      expect(fasterSimulation.dx(0), baseSimulation.dx(0));
      expect(fasterSimulation.x(0.08), greaterThan(baseSimulation.x(0.08)));
    },
  );
}
