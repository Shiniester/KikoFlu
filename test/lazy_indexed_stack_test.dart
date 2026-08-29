import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/lazy_indexed_stack.dart';

void main() {
  testWidgets('builds only visited tabs and keeps them mounted', (tester) async {
    final visited = <int>{0};

    Widget app(int index) {
      return MaterialApp(
        home: LazyIndexedStack(
          index: index,
          visitedIndices: visited,
          children: const [
            Text('home'),
            Text('search'),
            Text('settings'),
          ],
        ),
      );
    }

    await tester.pumpWidget(app(0));
    expect(find.text('home'), findsOneWidget);
    expect(find.text('search'), findsNothing);
    expect(find.text('settings'), findsNothing);

    visited.add(1);
    await tester.pumpWidget(app(1));
    expect(find.text('home', skipOffstage: false), findsOneWidget);
    expect(find.text('search'), findsOneWidget);
    expect(find.text('settings', skipOffstage: false), findsNothing);
  });
}
