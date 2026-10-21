import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/providers/audio_source_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/screens/blocked_items_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FixedAudioSourceNotifier extends AudioSourceNotifier {
  _FixedAudioSourceNotifier(AudioSource source) {
    state = source;
  }
}

class _BlockedItemsApi extends KikoeruApiService {
  final catalogTypes = <SearchType>[];
  final legacyTypes = <SearchType>[];
  int nativeFailuresRemaining;

  _BlockedItemsApi({this.nativeFailuresRemaining = 0});

  @override
  Future<List<Map<String, dynamic>>> getSearchCatalog(
    SearchType type, {
    CancelToken? cancelToken,
  }) async {
    catalogTypes.add(type);
    if (nativeFailuresRemaining > 0) {
      nativeFailuresRemaining--;
      throw StateError('catalog unavailable');
    }
    return [
      {
        'name': _catalogName(type),
        'sourcePath': '/${type.value}/native-item/',
        'count': 5,
      },
    ];
  }

  @override
  Future<List<dynamic>> getAllTags({CancelToken? cancelToken}) async {
    legacyTypes.add(SearchType.tag);
    return [
      {'id': 999999, 'name': '耳かき', 'count': 8},
    ];
  }

  @override
  Future<List<dynamic>> getAllVas({CancelToken? cancelToken}) async {
    legacyTypes.add(SearchType.va);
    return [
      {'id': 101, 'name': 'ASMR voice actor', 'count': 8},
    ];
  }

  @override
  Future<List<dynamic>> getAllCircles({CancelToken? cancelToken}) async {
    legacyTypes.add(SearchType.circle);
    return [
      {'id': 201, 'name': 'ASMR circle', 'count': 8},
    ];
  }
}

String _catalogName(SearchType type) => switch (type) {
  SearchType.tag => '耳かき',
  SearchType.va => 'JP voice actor',
  SearchType.circle => 'JP circle',
  _ => throw ArgumentError.value(type, 'type'),
};

String _tabLabel(SearchType type, S strings) => switch (type) {
  SearchType.tag => strings.searchTypeTag,
  SearchType.va => strings.searchTypeVa,
  SearchType.circle => strings.searchTypeCircle,
  _ => throw ArgumentError.value(type, 'type'),
};

String _expectedName(AudioSource source, SearchType type) {
  if (source == AudioSource.jpAsmr) return _catalogName(type);
  return switch (type) {
    SearchType.tag => '耳かき',
    SearchType.va => 'ASMR voice actor',
    SearchType.circle => 'ASMR circle',
    _ => throw ArgumentError.value(type, 'type'),
  };
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required _BlockedItemsApi api,
  required AudioSource source,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        kikoeruApiServiceProvider.overrideWithValue(api),
        audioSourceProvider.overrideWith(
          (ref) => _FixedAudioSourceNotifier(
            source == AudioSource.jpAsmr
                ? AudioSource.asmrOne
                : AudioSource.jpAsmr,
          ),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: BlockedItemsScreen(source: source),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _addCatalogItem(
  WidgetTester tester, {
  required SearchType type,
  required String name,
  required S strings,
}) async {
  if (type != SearchType.tag) {
    await tester.tap(find.text(_tabLabel(type, strings)));
    await tester.pumpAndSettle();
  }

  await tester.tap(find.byIcon(Icons.add));
  await tester.pumpAndSettle();

  final field = find.byType(TextField);
  await tester.enterText(field, name);
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();

  expect(find.byType(AlertDialog), findsOneWidget);
  expect(tester.widget<TextField>(field).controller!.text, name);
  await tester.tap(find.text(strings.add));
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

  for (final source in AudioSource.values) {
    for (final type in [SearchType.tag, SearchType.va, SearchType.circle]) {
      testWidgets('${source.label} blocks a selected ${type.label}', (
        tester,
      ) async {
        final api = _BlockedItemsApi();
        await _pumpScreen(tester, api: api, source: source);

        final screen = find.byType(BlockedItemsScreen);
        final strings = S.of(tester.element(screen));
        final name = _expectedName(source, type);
        await _addCatalogItem(tester, type: type, name: name, strings: strings);

        expect(
          api.catalogTypes,
          source == AudioSource.jpAsmr ? [type] : isEmpty,
        );
        expect(
          api.legacyTypes,
          source == AudioSource.asmrOne ? [type] : isEmpty,
        );

        final container = ProviderScope.containerOf(tester.element(screen));
        expect(
          container.read(audioSourceProvider),
          source == AudioSource.jpAsmr
              ? AudioSource.asmrOne
              : AudioSource.jpAsmr,
        );
        final blocked = container.read(blockedItemsBySourceProvider(source));
        expect(blocked.tags, type == SearchType.tag ? [name] : isEmpty);
        expect(blocked.cvs, type == SearchType.va ? [name] : isEmpty);
        expect(blocked.circles, type == SearchType.circle ? [name] : isEmpty);
        if (source == AudioSource.jpAsmr && type == SearchType.tag) {
          expect(find.text(name), findsOneWidget);
        }

        final otherSource = source == AudioSource.jpAsmr
            ? AudioSource.asmrOne
            : AudioSource.jpAsmr;
        final otherBlocked = container.read(
          blockedItemsBySourceProvider(otherSource),
        );
        expect(otherBlocked.tags, isEmpty);
        expect(otherBlocked.cvs, isEmpty);
        expect(otherBlocked.circles, isEmpty);
      });
    }
  }

  testWidgets('JP-ASMR catalog retry stays on the native catalog', (
    tester,
  ) async {
    final api = _BlockedItemsApi(nativeFailuresRemaining: 1);
    await _pumpScreen(tester, api: api, source: AudioSource.jpAsmr);
    final screen = find.byType(BlockedItemsScreen);
    final strings = S.of(tester.element(screen));

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text(strings.loadFailed), findsOneWidget);
    expect(api.catalogTypes, [SearchType.tag]);
    expect(api.legacyTypes, isEmpty);

    await tester.enterText(find.byType(TextField), 'manual block');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(strings.retry));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'manual block',
    );
    expect(api.catalogTypes, [SearchType.tag, SearchType.tag]);
    expect(api.legacyTypes, isEmpty);
    await tester.enterText(
      find.byType(TextField),
      _catalogName(SearchType.tag),
    );
    await tester.pumpAndSettle();
    expect(find.text(_catalogName(SearchType.tag)), findsWidgets);
  });
}
