import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/utils/snackbar_util.dart';

Widget _testApp(SnackBar snackBar) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) {
          return TextButton(
            onPressed: () => SnackBarUtil.showFromSnackBar(context, snackBar),
            child: const Text('show'),
          );
        },
      ),
    ),
  );
}

void main() {
  group('SnackBarUtil.showFromSnackBar', () {
    testWidgets('converts red text snackbar to unified error style', (
      tester,
    ) async {
      await tester.pumpWidget(
        _testApp(
          const SnackBar(content: Text('failed'), backgroundColor: Colors.red),
        ),
      );

      await tester.tap(find.text('show'));
      await tester.pump();

      expect(find.text('failed'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('extracts text from row content', (tester) async {
      await tester.pumpWidget(
        _testApp(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.info),
                Expanded(child: Text('row message')),
              ],
            ),
            backgroundColor: Colors.orange,
          ),
        ),
      );

      await tester.tap(find.text('show'));
      await tester.pump();

      expect(find.text('row message'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('keeps custom content inside the unified floating notice', (
      tester,
    ) async {
      await tester.pumpWidget(
        _testApp(const SnackBar(content: Icon(Icons.circle))),
      );

      await tester.tap(find.text('show'));
      await tester.pump();

      expect(find.byIcon(Icons.circle), findsOneWidget);
      final notice = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(notice.behavior, SnackBarBehavior.floating);
      expect(notice.margin, isNotNull);
      final margin = notice.margin! as EdgeInsets;
      expect(margin.left, greaterThanOrEqualTo(16));
      expect(margin.right, greaterThanOrEqualTo(16));
      expect(margin.bottom, inInclusiveRange(88, 144));
    });

    testWidgets('preserves actions and replaces the currently visible notice', (
      tester,
    ) async {
      var actionInvoked = false;
      await tester.pumpWidget(
        _testApp(
          SnackBar(
            content: const Text('action message'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => actionInvoked = true,
            ),
          ),
        ),
      );

      await tester.tap(find.text('show'));
      await tester.pump();
      await tester.tap(find.text('show'));
      await tester.pump(const Duration(milliseconds: 650));
      expect(find.byType(SnackBar), findsOneWidget);
      tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
      expect(actionInvoked, isTrue);
    });
  });
}
