import 'package:flutter/widgets.dart';

const double playerPageScrollTimeScale = 0.85;

class PlayerPageScrollPhysics extends ScrollPhysics {
  const PlayerPageScrollPhysics({super.parent});

  @override
  PlayerPageScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return PlayerPageScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring {
    final parentSpring = super.spring;
    return SpringDescription(
      mass: parentSpring.mass,
      stiffness:
          parentSpring.stiffness /
          (playerPageScrollTimeScale * playerPageScrollTimeScale),
      damping: parentSpring.damping / playerPageScrollTimeScale,
    );
  }
}
