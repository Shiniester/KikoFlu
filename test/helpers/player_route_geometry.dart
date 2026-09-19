import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Rect playerRouteRevealRect(WidgetTester tester) {
  final finder = find.byKey(
    const ValueKey('player-route-background-reveal'),
    skipOffstage: false,
  );
  final clip = tester.widget<ClipRect>(finder);
  return clip.clipper!.getClip(tester.getSize(finder));
}
