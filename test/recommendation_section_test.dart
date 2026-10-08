import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/recommendation_provider.dart';
import 'package:kikoeru_flutter/src/providers/work_detail_display_provider.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/enhanced_work_card.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/recommendation_section.dart';

class _Recommendations extends RecommendationNotifier {
  _Recommendations(super.ref, super.accessId);
  int requests = 0;
  void show(List<Work> works) {
    state = RecommendationState(recommendations: works);
  }

  @override
  Future<void> loadRecommendations(Work work) async {
    requests++;
  }
}

void main() {
  testWidgets(
    'recommendations align with details and use the home two-column cards',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late _Recommendations recommendations;
      final container = ProviderContainer(
        overrides: [
          recommendationProvider.overrideWith(
            (ref, id) => recommendations = _Recommendations(ref, id),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.all(16),
                    sliver: RecommendationSection(
                      work: Work(id: 9, title: 'Work'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      recommendations.show([
        for (var id = 1; id <= 6; id++) Work(id: id, title: 'Related work $id'),
      ]);
      await tester.pump();
      expect(find.byIcon(Icons.recommend_outlined), findsNothing);
      expect(tester.getRect(find.text('Related Works')).left, 16);
      final cards = find.byType(EnhancedWorkCard);
      expect(cards, findsNWidgets(6));
      final first = tester.getRect(cards.at(0));
      final second = tester.getRect(cards.at(1));
      final third = tester.getRect(cards.at(2));
      expect(first.left, 16);
      expect(first.top, second.top);
      expect(second.left - first.right, 8);
      expect(first.width, second.width);
      expect(third.top, greaterThan(first.bottom));
      expect(find.byType(Scrollable), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'hidden and offscreen recommendations do not load; approaching loads once',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      late _Recommendations recommendations;
      final container = ProviderContainer(
        overrides: [
          recommendationProvider.overrideWith(
            (ref, id) => recommendations = _Recommendations(ref, id),
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
      await tester.pump();
      expect(recommendations.requests, 0);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(recommendations.requests, 0);
      scroll.jumpTo(0);
      await settings.toggleRecommendations();
      await tester.pump();
      await tester.pump();
      expect(recommendations.requests, 0);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();
      expect(recommendations.requests, 1);
      recommendations.show([const Work(id: 10, title: 'Visit result')]);
      await tester.pump();
      scroll.jumpTo(0);
      await tester.pump();
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await settings.toggleRecommendations();
      await tester.pump();
      await tester.pump();
      await settings.toggleRecommendations();
      await tester.pump();
      await tester.pump();
      expect(recommendations.requests, 1);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(find.text('Visit result'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
