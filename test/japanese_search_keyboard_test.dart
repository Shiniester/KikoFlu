import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/providers/audio_source_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/screens/search_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';

class _JapaneseSourceNotifier extends AudioSourceNotifier {
  _JapaneseSourceNotifier() {
    state = AudioSource.jpAsmr;
  }
}

class _CatalogApi extends KikoeruApiService {
  final catalogTypes = <SearchType>[];

  @override
  Future<List<dynamic>> getAllTags({CancelToken? cancelToken}) async => [
    {'id': 999999, 'name': '耳かき', 'count': 5},
  ];

  @override
  Future<List<Map<String, dynamic>>> getSearchCatalog(
    SearchType type, {
    CancelToken? cancelToken,
  }) async {
    catalogTypes.add(type);
    return [
      {
        'name': '耳かき',
        'sourcePath': '/tag/%e8%80%b3%e3%81%8b%e3%81%8d/',
        'count': 5,
      },
    ];
  }
}

Future<void> _pumpSearchScreen(
  WidgetTester tester, {
  required _CatalogApi api,
  required AudioSourceNotifier sourceNotifier,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        kikoeruApiServiceProvider.overrideWithValue(api),
        audioSourceProvider.overrideWith((ref) => sourceNotifier),
        downloadSummaryProvider.overrideWith(
          (ref) => Stream.value(const DownloadTaskSummary.empty()),
        ),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: SearchScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets('JP-ASMR keyboard submit selects the highlighted catalog item', (
    tester,
  ) async {
    final api = _CatalogApi();
    await _pumpSearchScreen(
      tester,
      api: api,
      sourceNotifier: _JapaneseSourceNotifier(),
    );

    await tester.tap(find.text('标签'));
    await tester.pumpAndSettle();
    expect(api.catalogTypes, [SearchType.tag]);

    final field = find.byType(TextField).first;
    await tester.tap(field);
    await tester.enterText(field, '耳');
    await tester.pumpAndSettle();
    expect(find.text('耳かき (5)'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('标签: 耳かき'), findsOneWidget);
    expect(find.text('搜索 (1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ASMR.ONE keyboard submit adds typed tag without warning', (
    tester,
  ) async {
    final api = _CatalogApi();
    await _pumpSearchScreen(
      tester,
      api: api,
      sourceNotifier: AudioSourceNotifier(),
    );

    await tester.tap(find.text('标签'));
    await tester.pumpAndSettle();
    final field = find.byType(TextField).first;
    await tester.tap(field);
    await tester.enterText(field, '耳');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('标签: 耳'), findsOneWidget);
    expect(find.text('搜索 (1)'), findsOneWidget);
    expect(find.text('请输入搜索内容'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
