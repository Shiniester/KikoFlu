import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../missav_client.dart';
import '../video_models.dart';
import '../video_providers.dart';

class VideoAccountScreen extends ConsumerStatefulWidget {
  const VideoAccountScreen({super.key});

  @override
  ConsumerState<VideoAccountScreen> createState() => _VideoAccountScreenState();
}

class _VideoAccountScreenState extends ConsumerState<VideoAccountScreen> {
  late final MissavClient _client;
  bool _loading = false;
  bool _ready = false;
  String? _error;
  MissavVerificationRequiredException? _verificationError;

  @override
  void initState() {
    super.initState();
    _client = ref.read(videoClientProvider)..addListener(_accountChanged);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _client.initialize();
      await _client.checkBrowserAccess();
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _ready = true;
          _verificationError = error is MissavVerificationRequiredException
              ? error
              : null;
          _error = _verificationError == null
              ? S.of(context).videoSourceUnavailable
              : S.of(context).videoVerificationRequired;
        });
      }
    }
  }

  void _accountChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openBrowser({required bool requireLogin}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final verified = await ref.read(missavAccessVerifierProvider)(
        context,
        _client,
        sourceUrl: requireLogin
            ? _client.homeUrl
            : _verificationError?.sourceUrl ?? _client.homeUrl,
        requireLogin: requireLogin,
      );
      if (mounted && verified) {
        setState(() {
          _error = null;
          _verificationError = null;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _logout() async {
    final clearBrowserSession = ref.read(videoBrowserSessionCleanupProvider);
    setState(() => _loading = true);
    Object? logoutError;
    try {
      await _client.logout();
    } catch (error) {
      logoutError = error;
    }
    try {
      await clearBrowserSession();
    } catch (error) {
      logoutError ??= error;
    }
    if (logoutError != null && mounted) {
      SnackBarUtil.showFromSnackBar(
        context,
        SnackBar(content: Text(S.of(context).videoSourceUnavailable)),
      );
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _verifyAccess() async {
    await _openBrowser(requireLogin: false);
  }

  @override
  void dispose() {
    _client.removeListener(_accountChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final loggedIn = _client.isLoggedIn;
    return GlobalAudioPlayerWrapper(
      child: Scaffold(
        appBar: AppBar(title: Text(s.videoSourceAccount)),
        body: !_ready
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    shrinkWrap: true,
                    children: [
                      Icon(
                        Icons.account_circle_outlined,
                        size: 56,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      if (loggedIn) ...[
                        Text(
                          _client.accountName ?? s.videoSourceAccount,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: _loading ? null : _logout,
                          icon: const Icon(Icons.logout),
                          label: Text(s.logout),
                        ),
                      ] else ...[
                        Text(s.videoLoginRequired, textAlign: TextAlign.center),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _loading
                              ? null
                              : () => _openBrowser(requireLogin: true),
                          icon: _loading
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.login),
                          label: Text(s.login),
                        ),
                        OutlinedButton.icon(
                          onPressed: _loading ? null : _verifyAccess,
                          icon: const Icon(Icons.verified_user_outlined),
                          label: Text(s.videoVerifyAccess),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
