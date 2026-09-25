import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../screens/account_management_screen.dart';

class AudioAccountPrompt extends StatelessWidget {
  const AudioAccountPrompt({super.key});
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.account_circle_outlined, size: 48),
        const SizedBox(height: 12),
        Text(S.of(context).comicAnonymous),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AccountManagementScreen()),
          ),
          child: Text(S.of(context).accountManagement),
        ),
      ],
    ),
  );
}
