import 'package:flutter/widgets.dart';

/// Builds a tab only after it has been visited, then keeps it mounted.
class LazyIndexedStack extends StatelessWidget {
  const LazyIndexedStack({
    super.key,
    required this.index,
    required this.visitedIndices,
    required this.children,
  });

  final int index;
  final Set<int> visitedIndices;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    assert(index >= 0 && index < children.length);
    assert(visitedIndices.contains(index));

    return IndexedStack(
      index: index,
      children: List.generate(children.length, (childIndex) {
        if (!visitedIndices.contains(childIndex)) {
          return SizedBox.shrink(
            key: ValueKey('lazy-indexed-stack-placeholder-$childIndex'),
          );
        }
        return HeroMode(
          enabled: childIndex == index,
          child: children[childIndex],
        );
      }),
    );
  }
}
