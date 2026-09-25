import 'dart:convert';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:equatable/equatable.dart';

import '../models/user.dart';
import '../models/account.dart';
import '../services/kikoeru_api_service.dart';
import '../services/storage_service.dart';
import '../services/account_database.dart';
import '../services/log_service.dart';
import '../utils/server_utils.dart';

final _log = LogService.instance;

// Kikoeru API Service Provider
final kikoeruApiServiceProvider = Provider<KikoeruApiService>((ref) {
  return KikoeruApiService();
});

// Auth state
class AuthState extends Equatable {
  final User? currentUser;
  final String? token;
  final String? host;
  final bool isLoading;
  final String? error;
  final bool isLoggedIn;

  bool get isAnonymous => currentUser == null;

  const AuthState({
    this.currentUser,
    this.token,
    this.host,
    this.isLoading = false,
    this.error,
    this.isLoggedIn = false,
  });

  AuthState copyWith({
    User? currentUser,
    String? token,
    String? host,
    bool? isLoading,
    String? error,
    bool? isLoggedIn,
  }) {
    return AuthState(
      currentUser: currentUser ?? this.currentUser,
      token: token ?? this.token,
      host: host ?? this.host,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      isLoggedIn: isLoggedIn ?? this.isLoggedIn,
    );
  }

  @override
  List<Object?> get props => [
    currentUser,
    token,
    host,
    isLoading,
    error,
    isLoggedIn,
  ];
}

// Auth notifier
class AuthNotifier extends StateNotifier<AuthState> {
  final KikoeruApiService _apiService;
  late final Future<void> ready;
  int _authRevision = 0;
  Future<void> _pendingCommit = Future.value();

  // Serialize credential persistence while allowing logout to revoke requests immediately.
  Future<bool> _commitAuth(int revision, Future<void> Function() commit) async {
    final previous = _pendingCommit;
    final completed = Completer<void>();
    _pendingCommit = completed.future;
    await previous;
    try {
      if (revision != _authRevision) return false;
      await commit();
      return revision == _authRevision;
    } finally {
      completed.complete();
    }
  }

  AuthNotifier(this._apiService) : super(const AuthState()) {
    final host =
        StorageService.getString('server_host') ??
        ServerUtils.defaultRemoteHost;
    _apiService.init('', host, accountScope: 'anonymous');
    ready = _loadCurrentUser();
  }

  Future<void> _loadCurrentUser() async {
    final revision = _authRevision;
    try {
      _log.captureOutput('[Auth] Loading current user...');

      // First try to load from storage (faster)
      final token = StorageService.getString('auth_token');
      final host = StorageService.getString('server_host');
      final userJson = StorageService.getMap('current_user');

      if (StorageService.getBool('audio_anonymous') == true ||
          (token == null && userJson == null)) {
        await enterAnonymous(host: host);
        return;
      }

      _log.captureOutput(
        '[Auth] Stored token: ${token != null ? "exists" : "null"}',
      );
      _log.captureOutput('[Auth] Stored host: $host');

      if (token != null && host != null) {
        _apiService.init(
          token,
          host,
          accountScope: userJson?['name'] as String?,
        );

        User? user;
        if (userJson != null) {
          user = User.fromJson(userJson);
          _log.captureOutput('[Auth] Loaded user from storage: ${user.name}');
        }

        state = state.copyWith(
          token: token,
          host: host,
          currentUser: user,
          isLoggedIn: true,
        );

        // Validate token by fetching user info
        try {
          _log.captureOutput('[Auth] Validating token...');
          await _refreshUserInfo();
          _log.captureOutput(
            '[Auth] Token is valid, user logged in successfully',
          );
          return; // Token is valid, we're done
        } catch (e) {
          if (revision != _authRevision) return;
          _log.captureOutput('[Auth] Token validation failed: $e');
          // Token is invalid, try to re-login with saved account
        }
      }

      // If no valid token, try to load from database and re-login
      _log.captureOutput('[Auth] Checking database for active account...');
      final activeAccount = await AccountDatabase.instance.getActiveAccount();
      if (revision != _authRevision) return;

      if (activeAccount != null) {
        // Silently re-login with saved credentials
        _log.captureOutput(
          '[Auth] Found active account in database: ${activeAccount.username}',
        );
        _log.captureOutput('[Auth] Re-logging in with saved account...');

        _apiService.init(
          '',
          activeAccount.host,
          accountScope: activeAccount.username,
        );

        final success = await login(
          activeAccount.username,
          activeAccount.password,
          activeAccount.host,
          activeAccount.serverCookie,
          silent: true, // Don't show loading state
        );

        if (_authRevision != revision + 1) return;
        if (success) {
          _log.captureOutput('[Auth] Re-login successful');
          return;
        } else {
          _log.captureOutput(
            '[Auth] Re-login failed due to network or server issue',
          );
          // 网络问题导致登录失败，但我们有缓存的账户信息
          // 允许用户以离线模式进入应用（可以使用本地下载内容）
          _log.captureOutput(
            '[Auth] Entering offline mode with cached account',
          );

          // 使用缓存的账户信息设置基本状态
          _apiService.init(
            '',
            activeAccount.host,
            accountScope: activeAccount.username,
          );

          state = state.copyWith(
            currentUser: User(
              name: activeAccount.username,
              group: 'guest',
              loggedIn: false, // 标记为未完全登录（离线模式）
              host: activeAccount.host,
              password: activeAccount.password,
              token: '',
              lastUpdateTime: DateTime.now(),
            ),
            host: activeAccount.host,
            token: '',
            isLoggedIn: false, // 离线模式
            error: '网络连接失败，以离线模式启动',
          );

          _log.captureOutput('[Auth] Offline mode activated');
          return;
        }
      } else {
        _log.captureOutput('[Auth] No active account found in database');
      }

      // If all fails, logout
      _log.captureOutput('[Auth] No valid authentication found, logging out');
      await logout();
    } catch (e) {
      if (revision != _authRevision) return;
      _log.captureOutput('[Auth] Failed to load saved auth: $e');

      // 在异常情况下，也尝试检查是否有缓存账户
      try {
        final activeAccount = await AccountDatabase.instance.getActiveAccount();
        if (revision != _authRevision) return;
        if (activeAccount != null) {
          _log.captureOutput(
            '[Auth] Exception occurred but found cached account, entering offline mode',
          );

          _apiService.init(
            '',
            activeAccount.host,
            accountScope: activeAccount.username,
          );

          state = state.copyWith(
            currentUser: User(
              name: activeAccount.username,
              group: 'guest',
              loggedIn: false,
              host: activeAccount.host,
              password: activeAccount.password,
              token: '',
              lastUpdateTime: DateTime.now(),
            ),
            host: activeAccount.host,
            token: '',
            isLoggedIn: false,
            error: '网络连接失败，以离线模式启动',
          );

          return;
        }
      } catch (dbError) {
        _log.captureOutput('[Auth] Failed to check database: $dbError');
      }

      await logout();
    }
  }

  Future<bool> login(
    String username,
    String password,
    String host,
    String? serverCookie, {
    bool silent = false,
  }) async {
    final revision = ++_authRevision;
    final previous = state;
    final previousCookie = StorageService.getString('server_cookie');
    if (!silent) {
      state = state.copyWith(isLoading: true, error: null);
    }

    await _commitAuth(revision, () async {
      if (serverCookie != null && serverCookie.isNotEmpty) {
        await StorageService.setString('server_cookie', serverCookie);
      } else {
        await StorageService.remove('server_cookie');
      }
    });

    if (revision != _authRevision) return false;
    try {
      _log.captureOutput(
        '[Auth] Login attempt - username: $username, host: $host, silent: $silent',
      );

      // 删除主机地址末尾的斜杠，以免请求资源时出现地址错误
      if (host.endsWith("/")) {
        host = host.substring(0, host.length - 1);
      }

      // Initialize API service with empty token first
      _apiService.init('', host, accountScope: username);

      // Attempt login
      final response = await _apiService.login(username, password, host);
      if (revision != _authRevision) return false;

      final token = response['token'] as String?;
      if (token == null) {
        throw Exception('No token received from server');
      }

      _log.captureOutput('[Auth] Login successful, received token');

      // Normalize host URL to include protocol
      String normalizedHost;
      if (host.startsWith('http://') || host.startsWith('https://')) {
        normalizedHost = host;
      } else {
        // For remote hosts, use HTTPS; for localhost, use HTTP
        if (host.contains('localhost') ||
            host.startsWith('127.0.0.1') ||
            host.startsWith('192.168.')) {
          normalizedHost = 'http://$host';
        } else {
          normalizedHost = 'https://$host';
        }
      }

      _log.captureOutput('[Auth] Normalized host: $normalizedHost');

      // Update API service with real token and normalized host
      _apiService.init(token, normalizedHost, accountScope: username);

      // Get user info from login response or fetch it separately
      Map<String, dynamic> userInfo;
      if (response['user'] != null) {
        // Use user info from login response
        userInfo = response;
      } else {
        // Fetch user info separately
        userInfo = await _apiService.getUserInfo();
      }

      if (revision != _authRevision) return false;
      final user = User.fromJson(userInfo);

      // For official servers, verify the loggedIn field to ensure proper authentication
      // For self-hosted servers, skip this check as they may not return this field
      if (ServerUtils.isOfficialServer(normalizedHost) && !user.loggedIn) {
        throw Exception('Login failed: User not logged in');
      }

      // Create complete user object with credentials and token (using normalized host)
      final authenticatedUser = user.copyWith(
        password: password,
        host: normalizedHost,
        token: token,
        serverCookie: serverCookie,
        lastUpdateTime: DateTime.now(),
      );

      return await _commitAuth(revision, () async {
        // Save to storage (using normalized host)
        await StorageService.setString('auth_token', token);
        await StorageService.setBool('audio_anonymous', false);
        await StorageService.setString('server_host', normalizedHost);
        await StorageService.setMap('current_user', authenticatedUser.toJson());

        // Save or update account in database
        try {
          final existingAccounts = await AccountDatabase.instance
              .getAllAccounts();
          final existingAccount = existingAccounts.firstWhere(
            (acc) => acc.username == username && acc.host == normalizedHost,
            orElse: () => Account(
              username: username,
              password: password,
              host: normalizedHost,
              serverCookie: serverCookie,
              isActive: true,
              createdAt: DateTime.now(),
            ),
          );

          if (existingAccount.id != null) {
            // Update existing account
            await AccountDatabase.instance.updateAccount(
              existingAccount.copyWith(
                password: password,
                isActive: true,
                serverCookie: serverCookie,
                lastUsedAt: DateTime.now(),
              ),
            );
          } else {
            // Create new account
            await AccountDatabase.instance.createAccount(
              Account(
                username: username,
                password: password,
                host: normalizedHost,
                serverCookie: serverCookie,
                isActive: true,
                createdAt: DateTime.now(),
                lastUsedAt: DateTime.now(),
              ),
            );
          }
          _log.captureOutput('[Auth] Account saved to database');
        } catch (e) {
          _log.captureOutput('[Auth] Failed to save account to database: $e');
        }

        if (revision != _authRevision) return;
        state = state.copyWith(
          currentUser: authenticatedUser,
          token: token,
          host: normalizedHost,
          isLoading: false,
          isLoggedIn: true,
        );

        _log.captureOutput('[Auth] Login completed, state updated');
      });
    } catch (e) {
      _log.captureOutput('[Auth] Login error: $e');
      if (revision != _authRevision) return false;
      if (!await _commitAuth(
        revision,
        () => _restoreClient(previous, previousCookie),
      )) {
        return false;
      }

      if (!silent) {
        state = state.copyWith(
          isLoading: false,
          error: 'Login failed: ${e.toString()}',
        );
      }
      return false;
    }
  }

  Future<bool> register(
    String username,
    String password,
    String host, [
    String? serverCookie,
  ]) async {
    final revision = ++_authRevision;
    final previous = state;
    final previousCookie = StorageService.getString('server_cookie');
    state = state.copyWith(isLoading: true, error: null);

    await _commitAuth(revision, () async {
      if (serverCookie != null && serverCookie.isNotEmpty) {
        await StorageService.setString('server_cookie', serverCookie);
      } else {
        await StorageService.remove('server_cookie');
      }
    });

    if (revision != _authRevision) return false;
    try {
      // Initialize API service
      _apiService.init('', host, accountScope: username);

      // Attempt registration
      final response = await _apiService.register(username, password, host);
      if (revision != _authRevision) return false;

      final token = response['token'] as String?;
      if (token == null) {
        throw Exception('No token received from server');
      }

      // Normalize host URL to include protocol
      String normalizedHost;
      if (host.startsWith('http://') || host.startsWith('https://')) {
        normalizedHost = host;
      } else {
        // For remote hosts, use HTTPS; for localhost, use HTTP
        if (host.contains('localhost') ||
            host.startsWith('127.0.0.1') ||
            host.startsWith('192.168.')) {
          normalizedHost = 'http://$host';
        } else {
          normalizedHost = 'https://$host';
        }
      }

      // Update API service with token and normalized host
      _apiService.init(token, normalizedHost, accountScope: username);

      // Get user info from registration response or fetch it separately
      Map<String, dynamic> userInfo;
      if (response['user'] != null) {
        // Use user info from registration response
        userInfo = response;
      } else {
        // Fetch user info separately
        userInfo = await _apiService.getUserInfo();
      }

      if (revision != _authRevision) return false;
      final user = User.fromJson(userInfo);

      // For official servers, verify the loggedIn field to ensure proper authentication
      // For self-hosted servers, skip this check as they may not return this field
      if (ServerUtils.isOfficialServer(normalizedHost) && !user.loggedIn) {
        throw Exception('Registration failed: User not logged in');
      }

      // Create complete user object with credentials and token (using normalized host)
      final authenticatedUser = user.copyWith(
        password: password,
        host: normalizedHost,
        token: token,
        serverCookie: serverCookie,
        lastUpdateTime: DateTime.now(),
      );

      return await _commitAuth(revision, () async {
        // Save to storage (using normalized host)
        await StorageService.setString('auth_token', token);
        await StorageService.setBool('audio_anonymous', false);
        await StorageService.setString('server_host', normalizedHost);
        await StorageService.setMap('current_user', authenticatedUser.toJson());

        // Save account to database
        try {
          await AccountDatabase.instance.createAccount(
            Account(
              username: username,
              password: password,
              host: normalizedHost,
              isActive: true,
              serverCookie: serverCookie,
              createdAt: DateTime.now(),
              lastUsedAt: DateTime.now(),
            ),
          );
          _log.captureOutput('[Auth] Registered account saved to database');
        } catch (e) {
          _log.captureOutput(
            '[Auth] Failed to save registered account to database: $e',
          );
        }

        if (revision != _authRevision) return;
        state = state.copyWith(
          currentUser: authenticatedUser,
          token: token,
          host: normalizedHost,
          isLoading: false,
          isLoggedIn: true,
        );
      });
    } catch (e) {
      String errorMessage = 'Registration failed: ${e.toString()}';
      if (revision != _authRevision) return false;
      if (!await _commitAuth(
        revision,
        () => _restoreClient(previous, previousCookie),
      )) {
        return false;
      }

      if (e is KikoeruApiException && e.originalError is DioException) {
        final dioError = e.originalError as DioException;
        if (dioError.response != null && dioError.response?.statusCode == 403) {
          final data = dioError.response?.data;
          if (data is Map && data['error'] != null) {
            errorMessage = data['error'];
          } else if (data is String) {
            try {
              final json = jsonDecode(data);
              if (json is Map && json['error'] != null) {
                errorMessage = json['error'];
              }
            } catch (_) {
              // Ignore json decode error
            }
          }
        }
      }

      state = state.copyWith(isLoading: false, error: errorMessage);
      return false;
    }
  }

  Future<void> _refreshUserInfo() async {
    final revision = _authRevision;
    try {
      final userInfo = await _apiService.getUserInfo();
      if (revision != _authRevision) return;
      final user = User.fromJson(userInfo);

      // For official servers, verify the loggedIn field
      // For self-hosted servers, skip this check as they may not return this field
      if (ServerUtils.isOfficialServer(state.host) && !user.loggedIn) {
        throw Exception('User not logged in');
      }

      await _commitAuth(revision, () async {
        await StorageService.setMap('current_user', user.toJson());
        if (revision != _authRevision) return;

        state = state.copyWith(currentUser: user);
      });
    } catch (e) {
      _log.captureOutput('Failed to refresh user info: $e');
      // Rethrow the exception so caller can handle it
      rethrow;
    }
  }

  Future<void> updateHost(String host) async {
    if (state.token != null) {
      // Normalize host URL to include protocol
      String normalizedHost;
      if (host.startsWith('http://') || host.startsWith('https://')) {
        normalizedHost = host;
      } else {
        // For remote hosts, use HTTPS; for localhost, use HTTP
        if (host.contains('localhost') ||
            host.startsWith('127.0.0.1') ||
            host.startsWith('192.168.')) {
          normalizedHost = 'http://$host';
        } else {
          normalizedHost = 'https://$host';
        }
      }

      // 更新host时同步serverCookie配置
      final cookie = state.currentUser?.serverCookie;
      if (cookie != null && cookie.isNotEmpty) {
        await StorageService.setString('server_cookie', cookie);
      } else {
        await StorageService.remove('server_cookie');
      }

      _apiService.init(
        state.token!,
        normalizedHost,
        accountScope: state.currentUser?.name,
      );
      await StorageService.setString('server_host', normalizedHost);
      state = state.copyWith(host: normalizedHost);
    }
  }

  Future<void> logout() async {
    await enterAnonymous(host: state.host);
  }

  Future<void> _restoreClient(AuthState previous, String? cookie) async {
    _apiService.init(
      previous.token ?? '',
      previous.host ?? ServerUtils.defaultRemoteHost,
      accountScope: previous.currentUser?.name ?? 'anonymous',
    );
    if (cookie == null) {
      await StorageService.remove('server_cookie');
    } else {
      await StorageService.setString('server_cookie', cookie);
    }
  }

  Future<void> enterAnonymous({String? host}) async {
    final revision = ++_authRevision;
    var server =
        host ??
        StorageService.getString('server_host') ??
        ServerUtils.defaultRemoteHost;
    if (!server.contains('://')) {
      server =
          '${server.startsWith('localhost') || server.startsWith('127.') || server.startsWith('192.168.') ? 'http' : 'https'}://$server';
    }
    server = server.replaceFirst(RegExp(r'/+$'), '');
    _apiService.init('', server, accountScope: 'anonymous');
    state = AuthState(host: server);
    await _commitAuth(revision, () async {
      await StorageService.remove('auth_token');
      await StorageService.remove('current_user');
      await StorageService.remove('server_cookie');
      await StorageService.setString('server_host', server);
      await StorageService.setBool('audio_anonymous', true);
      try {
        await AccountDatabase.instance.clearActiveAccount();
      } catch (e) {
        _log.captureOutput('[Auth] Failed to clear active account: $e');
      }
    });
  }

  Future<void> switchUser(User user) async {
    final revision = ++_authRevision;
    final token = user.token;
    final host = user.host;
    final serverCookie = user.serverCookie;

    if (token != null && host != null) {
      _log.captureOutput(
        '[Auth] Switching user - username: ${user.name}, host: $host',
      );

      await _commitAuth(revision, () async {
        if (serverCookie != null && serverCookie.isNotEmpty) {
          await StorageService.setString('server_cookie', serverCookie);
        } else {
          await StorageService.remove('server_cookie');
        }

        if (revision != _authRevision) return;
        _apiService.init(token, host, accountScope: user.name);
        await StorageService.setString('auth_token', token);
        await StorageService.setBool('audio_anonymous', false);
        await StorageService.setString('server_host', host);
        await StorageService.setMap('current_user', user.toJson());
        if (revision != _authRevision) return;

        state = state.copyWith(
          currentUser: user,
          token: token,
          host: host,
          isLoggedIn: true,
        );

        _log.captureOutput('[Auth] User switched successfully');
      });
    } else {
      throw Exception('Invalid user data: missing token or host');
    }
  }

  Future<List<User>> getSavedUsers() async {
    await StorageService.initSecondary();
    final userKeys = StorageService.getAllUserKeys();
    final users = <User>[];

    for (final key in userKeys) {
      if (key != 'current_user' &&
          key != 'auth_token' &&
          key != 'server_host') {
        final userData = StorageService.getUser<Map<String, dynamic>>(key);
        if (userData != null) {
          try {
            users.add(User.fromJson(userData));
          } catch (e) {
            // Invalid user data, remove it
            await StorageService.removeUser(key);
          }
        }
      }
    }

    return users;
  }

  Future<void> saveUser(User user) async {
    final key = 'user_${user.name}_${user.host}';
    await StorageService.setUser(key, user.toJson());
  }

  Future<void> removeUser(User user) async {
    final key = 'user_${user.name}_${user.host}';
    await StorageService.removeUser(key);

    // If removing current user, logout
    if (state.currentUser == user) {
      await logout();
    }
  }

  /// 重新尝试连接（用于从离线模式恢复）
  Future<void> retryConnection() async {
    _log.captureOutput('[Auth] Retrying connection...');
    await _loadCurrentUser();
  }

  void clearError() {
    state = state.copyWith(error: null);
  }
}

// Providers
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final apiService = ref.watch(kikoeruApiServiceProvider);
  return AuthNotifier(apiService);
});

// Convenience providers
final isLoggedInProvider = Provider<bool>((ref) {
  return ref.watch(authProvider).isLoggedIn;
});

final currentUserProvider = Provider<User?>((ref) {
  return ref.watch(authProvider).currentUser;
});

final authTokenProvider = Provider<String?>((ref) {
  return ref.watch(authProvider).token;
});

final serverHostProvider = Provider<String?>((ref) {
  return ref.watch(authProvider).host;
});
