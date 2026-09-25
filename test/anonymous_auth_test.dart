import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/services/storage_service.dart';

class _Api extends KikoeruApiService {
  String activeHost = '', activeToken = '';
  int loginCalls = 0;
  bool fail = false;
  Completer<Map<String, dynamic>>? pending;
  Completer<void>? started;
  @override
  void init(String token, String host, {String? accountScope}) {
    activeHost = host;
    activeToken = token;
  }

  Map<String, dynamic> get session => {
    'token': 'personal-token',
    'user': {'name': 'reader', 'loggedIn': true},
  };
  @override
  Future<Map<String, dynamic>> login(
    String username,
    String password,
    String host,
  ) async {
    loginCalls++;
    started?.complete();
    if (pending != null) return pending!.future;
    if (fail) throw Exception('Rejected');
    return session;
  }

  @override
  Future<Map<String, dynamic>> register(
    String username,
    String password,
    String host,
  ) async => session;
  @override
  Future<Map<String, dynamic>> getUserInfo() async => session;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'server_host': 'https://original.example',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });
  test('logout revokes a login response that arrives later', () async {
    final api = _Api();
    final auth = AuthNotifier(api);
    await auth.ready;
    api.pending = Completer<Map<String, dynamic>>();
    api.started = Completer<void>();
    final login = auth.login(
      'reader',
      'password',
      'https://original.example',
      null,
    );
    await api.started!.future;
    await auth.logout();
    api.pending!.complete(api.session);
    expect(await login, false);
    expect(auth.state.isAnonymous, true);
    expect(api.activeToken, '');
    expect(StorageService.getString('auth_token'), isNull);
    expect(StorageService.getMap('current_user'), isNull);
    auth.dispose();
    api.dispose();
  });
  test('fresh startup is anonymous with no account login request', () async {
    final api = _Api();
    final auth = AuthNotifier(api);
    await auth.ready;
    expect(auth.state.isAnonymous, true);
    expect(api.loginCalls, 0);
    expect(api.activeToken, '');
    expect(api.activeHost, 'https://original.example');
    auth.dispose();
    api.dispose();
  });
  test('failed login restores the original server and credentials', () async {
    final api = _Api();
    final auth = AuthNotifier(api);
    await auth.ready;
    expect(
      await auth.login(
        'reader',
        'password',
        'https://original.example',
        'session=original',
      ),
      true,
    );
    api.fail = true;
    expect(
      await auth.login(
        'other',
        'wrong',
        'https://other.example',
        'session=attempt',
      ),
      false,
    );
    expect(api.activeHost, 'https://original.example');
    expect(api.activeToken, 'personal-token');
    expect(StorageService.getString('server_cookie'), 'session=original');
    await auth.logout();
    expect(api.activeToken, '');
    expect(StorageService.getString('auth_token'), isNull);
    expect(StorageService.getString('server_cookie'), isNull);
    expect(auth.state.host, 'https://original.example');
    auth.dispose();
    api.dispose();
  });
  test(
    'registering from anonymous survives authentication restoration',
    () async {
      final api = _Api();
      final auth = AuthNotifier(api);
      await auth.ready;
      expect(
        await auth.register('reader', 'password', 'https://original.example'),
        true,
      );
      expect(StorageService.getBool('audio_anonymous'), false);
      auth.dispose();
      final restored = AuthNotifier(api);
      await restored.ready;
      expect(restored.state.currentUser?.name, 'reader');
      expect(restored.state.isLoggedIn, true);
      expect(api.activeToken, 'personal-token');
      restored.dispose();
      api.dispose();
    },
  );
}
