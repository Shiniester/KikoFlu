import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/utils/snackbar_util.dart';

Widget _testApp(SnackBar snackBar) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) {
          return ElevatedButton(
            onPressed: () => SnackBarUtil.showFromSnackBar(context, snackBar),
            child: const Text('show'),
          );
        },
      ),
    ),
  );
}

Widget _noticeTestApp(void Function(BuildContext context) showNotice) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showNotice(context),
          child: const Text('show'),
        ),
      ),
    ),
  );
}

void main() {
  tearDown(() {
    AppFloatingNotice.clearAll();
  });

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
      await tester.pumpAndSettle();

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
      await tester.pumpAndSettle();

      expect(find.text('row message'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('keeps custom content inside the unified top floating notice', (
      tester,
    ) async {
      await tester.pumpWidget(
        _testApp(const SnackBar(content: Icon(Icons.circle))),
      );

      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.circle), findsOneWidget);
      final notice = tester.widget<TopFloatingNoticeWidget>(
        find.byType(TopFloatingNoticeWidget),
      );
      expect(notice.topOffset, 16.0);
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
      await tester.pumpAndSettle();
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(find.byType(TopFloatingNoticeWidget), findsOneWidget);
      tester.widget<TextButton>(find.widgetWithText(TextButton, 'Undo')).onPressed!();
      expect(actionInvoked, isTrue);
    });
  });

  testWidgets('uses compact default durations by notice severity', (
    tester,
  ) async {
    Future<Duration> durationFor(
      void Function(BuildContext context) showNotice,
    ) async {
      await tester.pumpWidget(_noticeTestApp(showNotice));
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      return tester
          .widget<TopFloatingNoticeWidget>(find.byType(TopFloatingNoticeWidget))
          .duration;
    }

    expect(
      await durationFor((context) => SnackBarUtil.showSuccess(context, 'ok')),
      const Duration(milliseconds: 1200),
    );
    expect(
      await durationFor((context) => SnackBarUtil.showInfo(context, 'info')),
      const Duration(milliseconds: 1200),
    );
    expect(
      await durationFor(
        (context) => SnackBarUtil.showWarning(context, 'warning'),
      ),
      const Duration(seconds: 2),
    );
    expect(
      await durationFor((context) => SnackBarUtil.showError(context, 'error')),
      const Duration(seconds: 3),
    );
  });

  group('TopFloatingNotice gestures and interaction', () {
    testWidgets('swiping up dismisses the notice', (tester) async {
      await tester.pumpWidget(
        _noticeTestApp((context) => SnackBarUtil.showInfo(context, 'swipe up')),
      );

      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(find.text('swipe up'), findsOneWidget);

      await tester.drag(find.text('swipe up'), const Offset(0, -60));
      await tester.pumpAndSettle();
      expect(find.text('swipe up'), findsNothing);
    });

    testWidgets('swiping horizontally dismisses the notice', (tester) async {
      await tester.pumpWidget(
        _noticeTestApp(
          (context) => SnackBarUtil.showInfo(context, 'swipe right'),
        ),
      );

      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(find.text('swipe right'), findsOneWidget);

      await tester.drag(find.text('swipe right'), const Offset(80, 0));
      await tester.pumpAndSettle();
      expect(find.text('swipe right'), findsNothing);
    });

    testWidgets('tapping body does not dismiss the notice', (tester) async {
      await tester.pumpWidget(
        _noticeTestApp((context) => SnackBarUtil.showInfo(context, 'tap test')),
      );

      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(find.text('tap test'), findsOneWidget);

      await tester.tap(find.text('tap test'));
      await tester.pump();
      expect(find.text('tap test'), findsOneWidget);
    });
  });
}
