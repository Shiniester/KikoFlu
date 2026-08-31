import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/utils/reorder_utils.dart';

void main() {
  test('moves an item downward using the callback final index', () {
    final values = ['a', 'b', 'c'];

    expect(reorderByFinalIndex(values, 0, 2), isTrue);

    expect(values, ['b', 'c', 'a']);
  });

  test('moves an item upward using the callback final index', () {
    final values = ['a', 'b', 'c'];

    expect(reorderByFinalIndex(values, 2, 0), isTrue);

    expect(values, ['c', 'a', 'b']);
  });
}
