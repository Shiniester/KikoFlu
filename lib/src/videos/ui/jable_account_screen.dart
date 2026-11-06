import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../jable_client.dart';
import '../jable_verification.dart';
import '../video_models.dart';
import '../video_providers.dart';

class JableAccountScreen extends ConsumerStatefulWidget {
  const JableAccountScreen({super.key});

  @override
  ConsumerState<JableAccountScreen> createState() => _JableAccountScreenState();
}

class _JableAccountScreenState extends ConsumerState<JableAccountScreen> {
  late final JableClient _client;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _client = ref.read(jableVideoClientProvider);
    unawaited(_run(_check));
  }

  Future<void> _check() async {
    await _client.account.checkLogin();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openBrowser({required bool login}) async {
    final checked = await verifyJableAccess(
      context,
      _client,
      sourceUrl: login ? '${JableClient.origin}/login/' : _client.homeUrl,
      requireLogin: login,
    );
    if (checked && !login) await _check();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final account = _client.account;
    return GlobalAudioPlayerWrapper(
      child: Scaffold(
        appBar: AppBar(title: Text(s.videoJableAccount)),
        body: ListenableBuilder(
          listenable: account,
          builder: (context, _) => Center(
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
                  Text(
                    account.isLoggedIn
                        ? s.videoJableSignedIn
                        : s.videoJableLoginRequired,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            account.isLoggedIn
                                ? account.logout
                                : () => _openBrowser(login: true),
                          ),
                    icon: Icon(account.isLoggedIn ? Icons.logout : Icons.login),
                    label: Text(account.isLoggedIn ? s.logout : s.login),
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error is VideoVerificationRequired
                          ? s.videoVerificationRequired
                          : s.videoSourceUnavailable,
                      textAlign: TextAlign.center,
                    ),
                    TextButton(
                      onPressed: () => _run(_check),
                      child: Text(s.retry),
                    ),
                    OutlinedButton(
                      onPressed: () => _run(() => _openBrowser(login: false)),
                      child: Text(
                        _error is VideoVerificationRequired
                            ? s.videoVerifyAccess
                            : s.videoOpenSource,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
