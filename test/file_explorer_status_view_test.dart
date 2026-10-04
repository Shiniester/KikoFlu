import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/file_explorer_status_view.dart';

Widget _testApp(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: Scaffold(body: child),
  );
}

class _CountingPainter extends CustomPainter {
  _CountingPainter(this.onPaint);

  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) => onPaint();

  @override
  bool shouldRepaint(covariant _CountingPainter oldDelegate) => false;
}

void main() {
  testWidgets('renders loading state before all other states', (tester) async {
    await tester.pumpWidget(
      _testApp(
        const FileExplorerStatusView(
          isLoading: true,
          empty: true,
          emptyMessage: 'No files',
          errorMessage: 'Failed',
          child: Text('content'),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Failed'), findsNothing);
    expect(find.text('No files'), findsNothing);
    expect(find.text('content'), findsNothing);
  });

  testWidgets('loading spinner paint does not repaint its ancestor', (
    tester,
  ) async {
    var ancestorPaints = 0;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(400, 800)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Theme(
            data: ThemeData(),
            child: SizedBox(
              width: 400,
              height: 800,
              child: CustomPaint(
                painter: _CountingPainter(() => ancestorPaints++),
                child: const FileExplorerStatusView(
                  isLoading: true,
                  empty: false,
                  emptyMessage: 'No files',
                  child: SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final initialPaints = ancestorPaints;
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(ancestorPaints, initialPaints);
  });

  testWidgets('renders error state and retry action', (tester) async {
    var retryCount = 0;

    await tester.pumpWidget(
      _testApp(
        FileExplorerStatusView(
          isLoading: false,
          empty: false,
          emptyMessage: 'No files',
          errorMessage: 'Failed to load files',
          onRetry: () => retryCount++,
          child: const Text('content'),
        ),
      ),
    );

    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(find.text('Failed to load files'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));

    expect(retryCount, 1);
  });

  testWidgets('renders empty state', (tester) async {
    await tester.pumpWidget(
      _testApp(
        const FileExplorerStatusView(
          isLoading: false,
          empty: true,
          emptyMessage: 'No downloaded files',
          child: Text('content'),
        ),
      ),
    );

    expect(find.byIcon(Icons.folder_open), findsOneWidget);
    expect(find.text('No downloaded files'), findsOneWidget);
    expect(find.text('content'), findsNothing);
  });

  testWidgets('renders content when ready', (tester) async {
    await tester.pumpWidget(
      _testApp(
        const FileExplorerStatusView(
          isLoading: false,
          empty: false,
          emptyMessage: 'No files',
          child: Text('content'),
        ),
      ),
    );

    expect(find.text('content'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.folder_open), findsNothing);
  });
}
