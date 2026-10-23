import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_search_screen.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_collection_view.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('search supports keyboard submit, replay, delete, and clear', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final submitted = <String>[];
    const result = VideoItem(
      id: 'result-1',
      title: 'Video result',
      pageUrl: 'https://missav.ai/video-result',
    );

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (query, _) async {
            submitted.add(query);
            return const VideoSearchResults.collection([result]);
          },
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'actor',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(submitted, ['actor']);
    expect(find.text('Video result'), findsOneWidget);

    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.clear));
    await tester.pumpAndSettle();
    expect(find.text('actor'), findsOneWidget);

    await tester.tap(find.text('actor'));
    await tester.pumpAndSettle();
    expect(submitted, ['actor', 'actor']);

    await tester.tap(find.byTooltip(l10n.clear));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l10n.delete));
    await tester.pumpAndSettle();
    expect(find.text('actor'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'tag',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l10n.clearSearchHistory));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.confirm));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l10n.clear));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.history), findsNothing);
  });

  testWidgets('search result stays mounted when a detail route is pushed', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    const result = VideoItem(
      id: 'result-2',
      title: 'Persistent result',
      pageUrl: 'https://missav.ai/persistent-result',
    );

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (_, _) async => const VideoSearchResults.collection([result]),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
          onOpenVideo: (context, _) {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Video details')),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'persistent',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Persistent result'));
    await tester.pumpAndSettle();
    expect(find.text('Video details'), findsOneWidget);

    Navigator.of(tester.element(find.text('Video details'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('Persistent result'), findsOneWidget);
  });

  testWidgets(
    'account collection results clear on account change while covered',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final client = _TestAccountClient();
      var searches = 0;
      const privateResult = VideoItem(
        id: 'private-result',
        title: 'Private account result',
        pageUrl: 'https://missav.ai/private-result',
      );

      await tester.pumpWidget(
        _app(
          VideoSearchScreen(
            title: 'Favorites search',
            initialQuery: 'actor',
            accountClient: client,
            search: (_, _) async {
              searches++;
              return const VideoSearchResults.collection([privateResult]);
            },
            browsePage: (url) async =>
                VideoCatalogPage(title: 'Results', url: url),
            onOpenVideo: (context, _) {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Video details')),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private account result'), findsOneWidget);
      client.notifyUnrelatedChange();
      await tester.pump();
      expect(find.text('Private account result'), findsOneWidget);
      await tester.tap(find.text('Private account result'));
      await tester.pumpAndSettle();

      client.changeAccount('Account B');
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('Video details'))).pop();
      await tester.pumpAndSettle();

      expect(find.text('Private account result'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('video-search-input')))
            .controller
            ?.text,
        'actor',
      );
      expect(searches, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      client.dispose();
    },
  );

  testWidgets('verification retry reruns the failed catalog search', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var attempts = 0;
    var verifiedSource = '';
    const result = VideoItem(
      id: 'verified-result',
      title: 'Verified result',
      pageUrl: 'https://missav.ai/verified-result',
    );

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (query, _) async {
            attempts++;
            if (attempts == 1) {
              throw const MissavVerificationRequiredException(
                sourceUrl: 'https://missav.ai/en/search?q=actor',
              );
            }
            return const VideoSearchResults.collection([result]);
          },
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
          verifyAccess: (_, error) async {
            verifiedSource = error.sourceUrl ?? '';
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'actor',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.text(l10n.videoVerifyAccess));
    await tester.pumpAndSettle();

    expect(verifiedSource, 'https://missav.ai/en/search?q=actor');
    expect(attempts, 2);
    expect(find.text('Verified result'), findsOneWidget);
  });

  testWidgets('small-grid video titles fit a narrow screen', (tester) async {
    SharedPreferences.setMockInitialValues({'video_layout_type': 'smallGrid'});
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final items = [
      for (var index = 0; index < 18; index++)
        VideoItem(
          id: 'small-grid-$index',
          title:
              'A very long video title that must wrap across two lines in the small grid $index',
          pageUrl: 'https://missav.ai/small-grid-$index',
        ),
    ];

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          initialQuery: 'small grid',
          search: (_, _) async => VideoSearchResults.collection(items),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
        textScale: 1.3,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(items.first.title), findsOneWidget);
    final cover = find.descendant(
      of: find.byType(VideoCard).first,
      matching: find.byType(Stack),
    );
    final coverSize = tester.getSize(cover);
    expect(coverSize.width / coverSize.height, closeTo(16 / 9, .02));
  });
}

Widget _app(Widget home, {double textScale = 1}) => ProviderScope(
  child: MaterialApp(
    locale: const Locale('en'),
    supportedLocales: S.supportedLocales,
    localizationsDelegates: S.localizationsDelegates,
    theme: ThemeData(useMaterial3: true),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: home,
  ),
);

class _TestAccountClient extends MissavClient {
  bool loggedIn = true;
  String? name = 'Account A';

  @override
  bool get isLoggedIn => loggedIn;

  @override
  String? get accountName => name;

  void changeAccount(String accountName) {
    name = accountName;
    notifyListeners();
  }

  void notifyUnrelatedChange() => notifyListeners();
}
