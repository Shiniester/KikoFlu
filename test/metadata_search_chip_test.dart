import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/audio_source_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/screens/search_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/metadata_search_chip.dart';
import 'package:kikoeru_flutter/src/widgets/tag_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _testApp(Widget child) {
  return MaterialApp(
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  );
}

class _RouteSearchCall {
  const _RouteSearchCall(this.keyword, this.source, this.ageRating);

  final String keyword;
  final AudioSource source;
  final AgeRating ageRating;
}

class _RouteSearchApi extends KikoeruApiService {
  final calls = <_RouteSearchCall>[];

  @override
  Future<Map<String, dynamic>> searchWorks({
    required String keyword,
    int page = 1,
    int pageSize = 40,
    AudioSource source = AudioSource.asmrOne,
    List<SearchCondition> conditions = const [],
    String? order,
    String? sort,
    int? subtitle,
    int? seed,
    bool includeTranslationWorks = true,
    AgeRating ageRating = AgeRating.all,
    CancelToken? cancelToken,
  }) async {
    calls.add(_RouteSearchCall(keyword, source, ageRating));
    return {
      'works': <dynamic>[],
      'pagination': {'totalCount': 0, 'hasMore': false},
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  group('MetadataSearchChip', () {
    testWidgets('renders an action chip and runs the provided tap callback', (
      tester,
    ) async {
      var tapped = 0;

      await tester.pumpWidget(
        _testApp(
          MetadataSearchChip(
            label: 'Tag',
            searchKeyword: 'Tag',
            searchTypeLabel: 'Tag',
            searchParams: const {'tagId': 1},
            chipTone: MetadataChipTone.secondary,
            onTap: () => tapped++,
          ),
        ),
      );

      expect(find.byType(ActionChip), findsOneWidget);
      expect(find.text('Tag'), findsOneWidget);

      await tester.tap(find.byType(ActionChip));
      expect(tapped, 1);
    });

    testWidgets('renders an input chip and runs the delete callback', (
      tester,
    ) async {
      var deleted = 0;

      await tester.pumpWidget(
        _testApp(
          MetadataSearchChip(
            label: 'Circle',
            searchKeyword: 'Circle',
            searchTypeLabel: 'Circle',
            searchParams: const {'circleId': 2},
            chipTone: MetadataChipTone.secondary,
            onDeleted: () => deleted++,
          ),
        ),
      );

      expect(find.byType(InputChip), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      expect(deleted, 1);
    });

    testWidgets('uses compact custom style and long press callback', (
      tester,
    ) async {
      var longPressed = 0;

      await tester.pumpWidget(
        _testApp(
          MetadataSearchChip(
            label: 'VA',
            searchKeyword: 'VA',
            searchTypeLabel: 'VA',
            searchParams: const {'vaId': 3},
            chipTone: MetadataChipTone.tertiary,
            fontSize: 12,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            borderRadius: 6,
            onLongPress: () => longPressed++,
          ),
        ),
      );

      expect(find.byType(ActionChip), findsNothing);
      expect(find.byType(GestureDetector), findsOneWidget);

      final text = tester.widget<Text>(find.text('VA'));
      expect(text.style?.fontSize, 12);

      await tester.longPress(find.text('VA'));
      expect(longPressed, 1);
    });

    testWidgets('disabled search keeps long press actions', (tester) async {
      var tapped = 0;
      var longPressed = 0;

      await tester.pumpWidget(
        _testApp(
          MetadataSearchChip(
            label: 'JP tag',
            searchKeyword: 'JP tag',
            searchTypeLabel: 'Tag',
            searchParams: const {'tagId': 1},
            chipTone: MetadataChipTone.secondary,
            searchEnabled: false,
            fontSize: 12,
            onTap: () => tapped++,
            onLongPress: () => longPressed++,
          ),
        ),
      );

      await tester.tap(find.text('JP tag'));
      expect(tapped, 0);

      await tester.longPress(find.text('JP tag'));
      expect(longPressed, 1);
    });
  });

  group('metadata chip wrappers', () {
    testWidgets('TagChip delegates rendering and custom tap handling', (
      tester,
    ) async {
      var tapped = 0;

      await tester.pumpWidget(
        _testApp(
          TagChip(
            tag: const Tag(id: 999999, name: 'custom tag'),
            onTap: () => tapped++,
          ),
        ),
      );

      expect(find.byType(ActionChip), findsOneWidget);
      expect(find.text('custom tag'), findsOneWidget);

      await tester.tap(find.byType(ActionChip));
      expect(tapped, 1);
    });

    testWidgets('JP tag routes by original name and pins its source', (
      tester,
    ) async {
      final api = _RouteSearchApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            kikoeruApiServiceProvider.overrideWithValue(api),
            audioSourceProvider.overrideWith((ref) => AudioSourceNotifier()),
            currentTrackProvider.overrideWith((ref) => Stream.value(null)),
            downloadSummaryProvider.overrideWith(
              (ref) => Stream.value(const DownloadTaskSummary.empty()),
            ),
          ],
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: Scaffold(
              body: Center(
                child: TagChip(
                  tag: Tag(
                    id: -42,
                    name: 'original tag',
                    names: {'en': 'Localized tag'},
                  ),
                  source: AudioSource.jpAsmr,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Localized tag'));
      await tester.pumpAndSettle();

      final routedScreen = tester.widget<SearchScreen>(
        find.byType(SearchScreen),
      );
      expect(routedScreen.source, AudioSource.jpAsmr);
      expect(routedScreen.initialKeyword, 'original tag');
      expect(routedScreen.initialSearchParams?['source'], 'jpAsmr');
      expect(routedScreen.initialSearchParams?.containsKey('tagId'), isFalse);
      expect(api.calls, hasLength(1));
      expect(api.calls.single.source, AudioSource.jpAsmr);
      expect(api.calls.single.keyword, 'original tag');
      expect(api.calls.single.ageRating, AgeRating.all);

      final globalSource = ProviderScope.containerOf(
        tester.element(find.byType(SearchScreen)),
      ).read(audioSourceProvider);
      expect(globalSource, AudioSource.asmrOne);

      final strings = S.of(tester.element(find.byType(SearchScreen)));
      await tester.tap(find.byKey(const ValueKey('audio-search-sort-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.ageRatingGeneral));
      await tester.pumpAndSettle();
      expect(api.calls, hasLength(2));
      expect(api.calls.last.keyword, 'original tag');
      expect(api.calls.last.source, AudioSource.jpAsmr);
      expect(api.calls.last.ageRating, AgeRating.general);
      expect(tester.takeException(), isNull);
    });
  });
}
