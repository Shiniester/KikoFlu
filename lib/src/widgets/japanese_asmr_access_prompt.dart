import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../services/japanese_asmr_service.dart';
import '../utils/ui_tokens.dart';
import 'async_state_view.dart';

class JapaneseAsmrAccessPrompt extends StatefulWidget {
  const JapaneseAsmrAccessPrompt({
    super.key,
    required this.onVerified,
    required this.onRetry,
  });

  final VoidCallback onVerified;
  final VoidCallback onRetry;

  @override
  State<JapaneseAsmrAccessPrompt> createState() =>
      _JapaneseAsmrAccessPromptState();
}

class _JapaneseAsmrAccessPromptState extends State<JapaneseAsmrAccessPrompt> {
  bool _isVerifying = false;
  bool _verificationFailed = false;

  bool get _supportsInAppVerification =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _verify() async {
    if (_isVerifying) return;
    setState(() {
      _isVerifying = true;
      _verificationFailed = false;
    });
    try {
      final strings = S.of(context);
      final verified = await JapaneseAsmrService.instance.verifyAccess(
        title: strings.jpAsmrVerificationTitle,
        closeLabel: strings.close,
      );
      if (mounted && verified) widget.onVerified();
    } on PlatformException {
      if (mounted) setState(() => _verificationFailed = true);
    } on MissingPluginException {
      if (mounted) setState(() => _verificationFailed = true);
    } finally {
      if (mounted) setState(() => _isVerifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = S.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final supported = _supportsInAppVerification;
    return AsyncStateView(
      icon: _isVerifying
          ? const SizedBox.square(
              dimension: 40,
              child: CircularProgressIndicator(),
            )
          : Icon(Icons.public_off, size: 64, color: colorScheme.error),
      title: Text(
        strings.jpAsmrVerificationTitle,
        style: Theme.of(context).textTheme.titleLarge,
      ),
      message: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(strings.jpAsmrVerificationMessage, textAlign: TextAlign.center),
          if (_verificationFailed || !supported) ...[
            const SizedBox(height: UiSpacing.small),
            Text(
              _verificationFailed
                  ? strings.jpAsmrVerificationFailed
                  : strings.jpAsmrVerificationUnsupported,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
      action: supported
          ? ElevatedButton.icon(
              onPressed: _isVerifying ? null : _verify,
              icon: _isVerifying
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.verified_user_outlined),
              label: Text(strings.jpAsmrVerify),
            )
          : ElevatedButton.icon(
              onPressed: widget.onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(strings.retry),
            ),
    );
  }
}
