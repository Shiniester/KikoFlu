import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../missav_client.dart';
import '../video_providers.dart';

class VideoAccountScreen extends ConsumerStatefulWidget {
  const VideoAccountScreen({super.key});

  @override
  ConsumerState<VideoAccountScreen> createState() => _VideoAccountScreenState();
}

class _VideoAccountScreenState extends ConsumerState<VideoAccountScreen> {
  late final MissavClient _client;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = ref.read(videoClientProvider)..addListener(_accountChanged);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _client.initialize();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _ready = true;
          _error = S.of(context).videoSourceUnavailable;
        });
      }
    }
  }

  void _accountChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _client.login(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(S.of(context).loginSuccess)));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _isVerificationError(error)
            ? S.of(context).videoVerificationRequired
            : S.of(context).loginFailed;
      });
    }
  }

  Future<void> _logout() async {
    setState(() => _loading = true);
    try {
      await _client.logout();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).videoSourceUnavailable)),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openSource() async {
    final uri = Uri.tryParse(_client.homeUrl);
    if (uri == null) return;
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).videoSourceUnavailable)),
      );
    }
  }

  @override
  void dispose() {
    _client.removeListener(_accountChanged);
    _emailController.dispose();
    _passwordController.dispose();
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
                        const SizedBox(height: 16),
                        TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.username],
                          decoration: InputDecoration(
                            labelText: s.videoEmail,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _passwordController,
                          obscureText: true,
                          textInputAction: TextInputAction.done,
                          autofillHints: const [AutofillHints.password],
                          onSubmitted: (_) => unawaited(_login()),
                          decoration: InputDecoration(
                            labelText: s.password,
                            border: const OutlineInputBorder(),
                          ),
                        ),
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
                        FilledButton(
                          onPressed: _loading ? null : _login,
                          child: _loading
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(s.login),
                        ),
                        TextButton(
                          onPressed: _openSource,
                          child: Text(s.videoRegisterOnSource),
                        ),
                        TextButton(
                          onPressed: _openSource,
                          child: Text(s.videoResetPasswordOnSource),
                        ),
                        TextButton(
                          onPressed: _openSource,
                          child: Text(s.videoPasswordOnSource),
                        ),
                      ],
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _openSource,
                        icon: const Icon(Icons.open_in_new),
                        label: Text(s.videoOpenSource),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

bool _isVerificationError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('verif') ||
      message.contains('challenge') ||
      message.contains('captcha') ||
      message.contains('403');
}
