import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_progress_action_button.dart';

Widget _testApp(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: Scaffold(appBar: AppBar(actions: [child])),
  );
}

void main() {
  testWidgets('renders mark action and handles taps', (tester) async {
    final semantics = tester.ensureSemantics();
    var tapCount = 0;

    await tester.pumpWidget(
      _testApp(
        WorkProgressActionButton(
          onPressed: () => tapCount++,
        ),
      ),
    );

    expect(find.text('Mark'), findsNothing);
    expect(find.byIcon(Icons.bookmark_border), findsOneWidget);
    expect(
      tester.getSize(find.byIcon(Icons.bookmark_border)),
      const Size(24, 24),
    );
    expect(find.byTooltip('Mark'), findsOneWidget);
    expect(tester.getSize(find.byType(WorkProgressActionButton)).width, 44);
    expect(tester.getSemantics(find.byType(IconButton)).tooltip, 'Mark');
    semantics.dispose();

    await tester.tap(find.byTooltip('Mark'));

    expect(tapCount, 1);
  });

  for (final state in [
    (value: 'marked', label: 'Marked', icon: Icons.bookmark),
    (value: 'listening', label: 'Listening', icon: Icons.headphones),
    (value: 'listened', label: 'Listened', icon: Icons.check_circle),
    (value: 'replay', label: 'Replay', icon: Icons.replay),
    (value: 'postponed', label: 'Postponed', icon: Icons.schedule),
  ]) {
    testWidgets('shows the ${state.value} icon without a visible label', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      var tapCount = 0;
      await tester.pumpWidget(
        _testApp(
          WorkProgressActionButton(
            progress: state.value,
            onPressed: () => tapCount++,
          ),
        ),
      );

      expect(find.text(state.label), findsNothing);
      expect(find.byTooltip(state.label), findsOneWidget);
      expect(tester.getSemantics(find.byType(IconButton)).tooltip, state.label);
      semantics.dispose();
      final icon = tester.widget<Icon>(find.byIcon(state.icon));
      expect(tester.getSize(find.byIcon(state.icon)), const Size(24, 24));
      expect(
        icon.color,
        Theme.of(tester.element(find.byIcon(state.icon))).colorScheme.primary,
      );
      await tester.tap(find.byIcon(state.icon));
      expect(tapCount, 1);
    });
  }

  testWidgets('renders loading state instead of action', (tester) async {
    await tester.pumpWidget(
      _testApp(
        const WorkProgressActionButton(
          progress: 'listened',
          isLoading: true,
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(IconButton), findsNothing);
    expect(find.text('Listened'), findsNothing);
    expect(tester.getSize(find.byType(WorkProgressActionButton)).width, 44);
  });
}
