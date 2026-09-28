import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/recommendation_provider.dart';
import 'package:kikoeru_flutter/src/providers/work_detail_display_provider.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/recommendation_section.dart';

class _Recommendations extends RecommendationNotifier {
  _Recommendations(super.ref, super.workId);
  int requests = 0;
  @override
  Future<void> loadRecommendations(Work work) async {
    requests++;
  }
}

void main() {
  testWidgets(
    'hidden and offscreen recommendations do not load; approaching loads once',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          recommendationProvider.overrideWith(
            (ref, id) => _Recommendations(ref, id),
          ),
        ],
      );
      addTearDown(container.dispose);
      final settings = container.read(workDetailDisplayProvider.notifier);
      await settings.toggleRecommendations();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                controller: scroll,
                slivers: const [
                  SliverToBoxAdapter(child: SizedBox(height: 3000)),
                  RecommendationSection(work: Work(id: 9, title: 'Work')),
                ],
              ),
            ),
          ),
        ),
      );
      final requests =
          container.read(recommendationProvider(9).notifier)
              as _Recommendations;
      await tester.pump();
      expect(requests.requests, 0);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(requests.requests, 0);
      scroll.jumpTo(0);
      await settings.toggleRecommendations();
      await tester.pump();
      await tester.pump();
      expect(requests.requests, 0);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();
      expect(requests.requests, 1);
      scroll.jumpTo(0);
      await tester.pump();
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await settings.toggleRecommendations();
      await tester.pump();
      await settings.toggleRecommendations();
      await tester.pump();
      expect(requests.requests, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
