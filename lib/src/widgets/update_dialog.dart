import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../providers/update_provider.dart';
import '../utils/snackbar_util.dart';

/// Formats a byte count into a human-readable string (B, KB, MB, GB).
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB'];
  final i = (log(bytes) / log(1024)).floor().clamp(0, suffixes.length - 1);
  return '${(bytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
}

/// Dialog displaying new version details with direct in-app download and installation.
class UpdateDialog extends ConsumerWidget {
  final UpdateInfo updateInfo;

  const UpdateDialog({super.key, required this.updateInfo});

  Future<void> _openReleaseUrl(BuildContext context) async {
    try {
      final uri = Uri.parse(updateInfo.releaseUrl);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && context.mounted) {
        SnackBarUtil.showError(context, S.of(context).cannotOpenLink);
      }
    } catch (e) {
      if (context.mounted) {
        SnackBarUtil.showError(
          context,
          S.of(context).openLinkFailed(e.toString()),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final updateState = ref.watch(updateControllerProvider);
    final updateController = ref.read(updateControllerProvider.notifier);

    final isDownloading = updateState.status == UpdateStatus.downloading;
    final isReadyToInstall = updateState.status == UpdateStatus.readyToInstall;
    final isInstalling = updateState.status == UpdateStatus.installing;
    final isFailed = updateState.status == UpdateStatus.failed;

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.system_update,
              color: colorScheme.onPrimaryContainer,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  updateInfo.isCrossChannel
                      ? S.of(context).updateChannelVersionAvailable
                      : S.of(context).newVersionFound,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'v${updateInfo.latestVersion}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                S
                    .of(context)
                    .newVersionAvailable(
                      updateInfo.latestVersion,
                      updateInfo.currentVersion,
                    ),
                style: theme.textTheme.bodyMedium,
              ),
              if (updateInfo.isCrossChannel) ...[
                const SizedBox(height: 8),
                Text(
                  S.of(context).crossChannelUpdateNotice,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (updateInfo.assetSize != null &&
                  updateInfo.assetSize! > 0) ...[
                const SizedBox(height: 6),
                Text(
                  S.of(context).packageSize(formatBytes(updateInfo.assetSize!)),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (updateInfo.releaseNotes != null &&
                  updateInfo.releaseNotes!.trim().isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  S.of(context).releaseNotes,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 180),
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      updateInfo.releaseNotes!.trim(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ],
              if (isDownloading) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: updateState.progress > 0 ? updateState.progress : null,
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${(updateState.progress * 100).toStringAsFixed(0)}%',
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      '${formatBytes(updateState.receivedBytes)} / ${formatBytes(updateState.totalBytes)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
              if (isInstalling) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        S.of(context).downloadingUpdate,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
              if (isReadyToInstall) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Icon(
                      Icons.check_circle,
                      color: Colors.green,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        S.of(context).downloadCompleted,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.green,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (isFailed) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: colorScheme.error,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        updateState.errorMessage ??
                            S.of(context).checkUpdateFailed,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (isDownloading)
          TextButton(
            onPressed: () => updateController.cancelDownload(),
            child: Text(S.of(context).cancelDownload),
          )
        else
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(S.of(context).remindLater),
          ),
        if (updateInfo.downloadUrl != null) ...[
          if (isReadyToInstall)
            FilledButton.icon(
              onPressed: () => updateController.install(),
              icon: const Icon(Icons.install_mobile, size: 18),
              label: Text(S.of(context).installUpdate),
            )
          else if (isDownloading)
            FilledButton(
              onPressed: null,
              child: Text(S.of(context).downloadingUpdate),
            )
          else
            FilledButton.icon(
              onPressed: () => updateController.startDownload(updateInfo),
              icon: const Icon(Icons.download, size: 18),
              label: Text(S.of(context).updateNow),
            ),
        ] else
          FilledButton.icon(
            onPressed: () => _openReleaseUrl(context),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text(S.of(context).openReleasePage),
          ),
      ],
    );
  }
}
