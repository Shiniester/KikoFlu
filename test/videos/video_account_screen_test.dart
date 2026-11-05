import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_account_screen.dart';
import 'package:kikoeru_flutter/src/videos/video_providers.dart';

typedef _MissavAccessVerifier =
    Future<bool> Function(
      BuildContext context,
      MissavClient client, {
      required String sourceUrl,
      bool requireLogin,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('refreshes a saved sign-in before showing the account state', (
    tester,
  ) async {
    final client = _TestMissavClient(restoredAccountName: 'saved-viewer');
    var cleanupCalls = 0;
    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl, requireLogin = false}) async =>
            false,
        clearBrowserSession: () async => cleanupCalls++,
      ),
    );
    await tester.pumpAndSettle();

    expect(client.browserAccessChecks, 1);
    expect(find.text('saved-viewer'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    final s = await S.delegate.load(const Locale('en'));
    await tester.tap(find.text(s.logout));
    await tester.pumpAndSettle();

    expect(client.logoutCalls, 1);
    expect(cleanupCalls, 1);
    expect(client.isLoggedIn, isFalse);
    expect(find.text(s.login), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('opens web verification and keeps a cancelled login retryable', (
    tester,
  ) async {
    final client = _TestMissavClient();
    final requests = <({String sourceUrl, bool requireLogin})>[];
    var loginAttempts = 0;
    final s = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(
        client,
        verifier:
            (
              _,
              verifiedClient, {
              required sourceUrl,
              requireLogin = false,
            }) async {
              requests.add((sourceUrl: sourceUrl, requireLogin: requireLogin));
              if (!requireLogin) return true;
              if (++loginAttempts == 1) return false;
              (verifiedClient as _TestMissavClient).confirmAccount(
                'new-viewer',
              );
              return true;
            },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text(s.videoVerifyAccess));
    await tester.pumpAndSettle();
    expect(requests.last, (
      sourceUrl: 'https://missav.ai/cn',
      requireLogin: false,
    ));

    await tester.tap(find.text(s.login));
    await tester.pumpAndSettle();
    expect(client.isLoggedIn, isFalse);
    expect(find.text(s.login), findsOneWidget);

    await tester.tap(find.text(s.login));
    await tester.pumpAndSettle();
    expect(requests.where((request) => request.requireLogin), hasLength(2));
    expect(requests.last, (
      sourceUrl: 'https://missav.ai/cn',
      requireLogin: true,
    ));
    expect(find.text('new-viewer'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}

Widget _app(
  _TestMissavClient client, {
  required _MissavAccessVerifier verifier,
  Future<void> Function()? clearBrowserSession,
}) => ProviderScope(
  overrides: [
    videoClientProvider.overrideWith((ref) => client),
    missavAccessVerifierProvider.overrideWithValue(verifier),
    videoBrowserSessionCleanupProvider.overrideWithValue(
      clearBrowserSession ?? () async {},
    ),
    currentTrackProvider.overrideWith((ref) => Stream.value(null)),
  ],
  child: MaterialApp(
    locale: const Locale('en'),
    supportedLocales: S.supportedLocales,
    localizationsDelegates: S.localizationsDelegates,
    theme: ThemeData(useMaterial3: true),
    home: const VideoAccountScreen(),
  ),
);

class _TestMissavClient extends MissavClient {
  _TestMissavClient({this.restoredAccountName})
    : super(secureStorage: _TestSecureStorage());

  final String? restoredAccountName;
  bool _loggedIn = false;
  String? _name;
  int browserAccessChecks = 0;
  int logoutCalls = 0;

  @override
  String get homeUrl => 'https://missav.ai/cn';

  @override
  bool get isLoggedIn => _loggedIn;

  @override
  String? get accountName => _name;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> checkBrowserAccess() async {
    browserAccessChecks++;
    if (restoredAccountName case final name?) confirmAccount(name);
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
    _loggedIn = false;
    _name = null;
    notifyListeners();
  }

  void confirmAccount(String name) {
    _loggedIn = true;
    _name = name;
    notifyListeners();
  }
}

class _TestSecureStorage implements FlutterSecureStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
