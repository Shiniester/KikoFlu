import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/update_provider.dart';
import '../utils/ui_tokens.dart';
import '../utils/snackbar_util.dart';
import '../widgets/scrollable_appbar.dart';
import '../widgets/settings_section.dart';
import '../widgets/update_dialog.dart';
import '../../l10n/app_localizations.dart';

class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  static const String _author = 'Shiniester';
  static const String _upstreamAuthor = 'pa-jesusf';
  static final Uri _originRepoUri = Uri.parse(
    'https://github.com/Shiniester/KikoFlu',
  );
  static final Uri _upstreamRepoUri = Uri.parse(
    'https://github.com/pa-jesusf/KikoFlu',
  );
  late final Future<_AboutData> _aboutFuture;
  UpdateChannel? _selectedUpdateChannel;
  bool _isCheckingUpdate = false;

  @override
  void initState() {
    super.initState();
    _aboutFuture = _loadAboutData();

    // Mark update as notified when entering this screen (hide red dot only)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final updateService = ref.read(updateServiceProvider);
      updateService.markAsNotified();
      // Only hide red dot, keep the "New Version" badge visible
      ref.read(showUpdateRedDotProvider.notifier).state = false;
    });
  }

  Future<_AboutData> _loadAboutData() async {
    final updateService = ref.read(updateServiceProvider);
    var version = 'Unknown';
    var buildNumber = '';
    var packageName = '';
    try {
      final info = await PackageInfo.fromPlatform();
      version = info.version;
      buildNumber = info.buildNumber;
      packageName = info.packageName;
    } catch (error, stackTrace) {
      debugPrint('AboutScreen: failed to load app version: $error');
      debugPrint(stackTrace.toString());
    }

    var licenseText = 'Failed to load LICENSE';
    try {
      final raw = await rootBundle.loadString('LICENSE');
      licenseText = raw.trim().isEmpty ? 'LICENSE is empty' : raw.trim();
    } catch (error, stackTrace) {
      debugPrint('AboutScreen: failed to load license: $error');
      debugPrint(stackTrace.toString());
    }

    final updateChannel = await updateService.getUpdateChannel(
      packageName: packageName,
    );
    _selectedUpdateChannel = updateChannel;

    return _AboutData(
      version: version,
      buildNumber: buildNumber,
      license: licenseText,
      updateChannel: updateChannel,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ScrollableAppBar(
        title: Text(S.of(context).aboutTitle, style: UiTextStyles.pageTitle),
      ),
      body: FutureBuilder<_AboutData>(
        future: _aboutFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sentiment_dissatisfied, size: 48),
                    const SizedBox(height: 12),
                    Text(S.of(context).failedToLoadAbout),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _aboutFuture = _loadAboutData();
                        });
                      },
                      child: Text(S.of(context).retry),
                    ),
                  ],
                ),
              ),
            );
          }

          final data = snapshot.data!;
          final versionLabel = data.buildNumber.isNotEmpty
              ? '${data.version} (${data.buildNumber})'
              : data.version;

          final primaryColor = Theme.of(context).colorScheme.primary;
          final isAndroid =
              !kIsWeb && Theme.of(context).platform == TargetPlatform.android;
          final updateChannel = _selectedUpdateChannel ?? data.updateChannel;
          final updateInfo = ref.watch(updateInfoProvider);
          final isCheckingUpdate = _isCheckingUpdate;
          final updateState = ref.watch(updateControllerProvider);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SettingsSectionCard(
                child: SettingsListTile(
                  key: const ValueKey('update-channel-setting'),
                  icon: Icons.system_update_alt,
                  iconColor: primaryColor,
                  title: S.of(context).updateChannel,
                  subtitle: _updateChannelLabel(context, updateChannel),
                  trailing: const Icon(Icons.arrow_drop_down),
                  onTap: () => _showUpdateChannelDialog(
                    updateChannel,
                    isAndroid: isAndroid,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Update check card - shown at top if update available
              if (updateInfo != null && updateInfo.hasNewVersion)
                SettingsSectionCard(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  child: ListTile(
                    leading: Icon(
                      updateState.status == UpdateStatus.downloading
                          ? Icons.downloading
                          : updateState.status == UpdateStatus.readyToInstall
                          ? Icons.download_done
                          : Icons.system_update,
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                    title: Text(
                      updateInfo.isCrossChannel
                          ? S.of(context).updateChannelVersionAvailable
                          : S.of(context).newVersionFound,
                      style: TextStyle(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSecondaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          S
                              .of(context)
                              .newVersionAvailable(
                                updateInfo.latestVersion,
                                updateInfo.currentVersion,
                              ),
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSecondaryContainer,
                          ),
                        ),
                        if (updateInfo.isCrossChannel) ...[
                          const SizedBox(height: 4),
                          Text(
                            S.of(context).crossChannelUpdateNotice,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSecondaryContainer,
                                ),
                          ),
                        ],
                        if (updateState.status == UpdateStatus.downloading) ...[
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: updateState.progress > 0
                                ? updateState.progress
                                : null,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${(updateState.progress * 100).toStringAsFixed(0)}% (${formatBytes(updateState.receivedBytes)} / ${formatBytes(updateState.totalBytes)})',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSecondaryContainer,
                                ),
                          ),
                        ],
                        if (updateState.status ==
                            UpdateStatus.readyToInstall) ...[
                          const SizedBox(height: 4),
                          Text(
                            S.of(context).downloadCompleted,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ],
                    ),
                    trailing: updateState.status == UpdateStatus.readyToInstall
                        ? FilledButton.tonal(
                            onPressed: () => ref
                                .read(updateControllerProvider.notifier)
                                .install(),
                            child: Text(S.of(context).installUpdate),
                          )
                        : updateState.status == UpdateStatus.downloading
                        ? IconButton(
                            icon: const Icon(Icons.close),
                            tooltip: S.of(context).cancelDownload,
                            onPressed: () => ref
                                .read(updateControllerProvider.notifier)
                                .cancelDownload(),
                          )
                        : FilledButton.tonal(
                            onPressed: () => _showUpdateDialog(updateInfo),
                            child: Text(S.of(context).updateNow),
                          ),
                    onTap: () => _showUpdateDialog(updateInfo),
                  ),
                ),
              if (updateInfo != null && updateInfo.hasNewVersion)
                const SizedBox(height: 16),

              SettingsSectionCard(
                child: SettingsListTile(
                  icon: Icons.verified,
                  iconColor: primaryColor,
                  title: S.of(context).versionInfo,
                  subtitle: S.of(context).currentVersion(versionLabel),
                  trailing: isCheckingUpdate
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          onPressed: _manualCheckUpdate,
                          child: Text(S.of(context).checkUpdate),
                        ),
                ),
              ),
              const SizedBox(height: 16),
              SettingsSectionCard(
                child: SettingsListTile(
                  icon: Icons.person_outline,
                  iconColor: primaryColor,
                  title: S.of(context).author,
                  subtitle: _author,
                ),
              ),
              const SizedBox(height: 16),
              SettingsSectionCard(
                child: SettingsListTile(
                  icon: Icons.link,
                  iconColor: primaryColor,
                  title: S.of(context).projectRepo,
                  subtitle: _originRepoUri.toString(),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => _openRepository(_originRepoUri),
                ),
              ),
              const SizedBox(height: 16),
              SettingsSectionCard(
                child: SettingsListTile(
                  icon: Icons.person_outline,
                  iconColor: primaryColor,
                  title: S.of(context).upstreamAuthor,
                  subtitle: _upstreamAuthor,
                ),
              ),
              const SizedBox(height: 16),
              SettingsSectionCard(
                child: SettingsListTile(
                  icon: Icons.link,
                  iconColor: primaryColor,
                  title: S.of(context).upstreamRepo,
                  subtitle: _upstreamRepoUri.toString(),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => _openRepository(_upstreamRepoUri),
                ),
              ),
              const SizedBox(height: 16),
              SettingsSectionCard(
                child: SettingsListTile(
                  icon: Icons.gavel_outlined,
                  iconColor: primaryColor,
                  title: S.of(context).openSourceLicense,
                  subtitle: 'LICENSE',
                  trailing: const Icon(Icons.arrow_forward_ios),
                  onTap: () => _showLicenseDialog(data.license),
                ),
              ),
              const SizedBox(height: 16),
              SettingsSectionCard(
                child: SettingsListTile(
                  icon: Icons.link,
                  iconColor: primaryColor,
                  title: 'EhTagTranslation',
                  subtitle: 'CC BY-NC-SA 3.0',
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () =>
                      _openUrl('https://github.com/EhTagTranslation/Database'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openRepository(Uri repository) async {
    await _openUrl(repository.toString());
  }

  Future<void> _openUrl(String urlString) async {
    try {
      final uri = Uri.parse(urlString);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        SnackBarUtil.showError(context, S.of(context).cannotOpenLink);
      }
    } catch (error) {
      if (!mounted) return;
      SnackBarUtil.showError(
        context,
        S.of(context).openLinkFailed(error.toString()),
      );
    }
  }

  Future<void> _manualCheckUpdate() async {
    await _checkUpdates(allowConcurrent: false);
  }

  Future<void> _checkUpdates({required bool allowConcurrent}) async {
    if (!allowConcurrent && _isCheckingUpdate) return;

    final updateService = ref.read(updateServiceProvider);
    final channelRevision = updateService.channelRevision;
    setState(() => _isCheckingUpdate = true);

    try {
      final channel =
          _selectedUpdateChannel ?? await updateService.getUpdateChannel();
      final updateInfo = await updateService.checkForUpdates(
        force: true,
        channel: channel,
      );

      if (!mounted || channelRevision != updateService.channelRevision) return;
      ref.read(updateInfoProvider.notifier).state =
          updateInfo?.hasNewVersion == true ? updateInfo : null;
      ref.read(hasNewVersionProvider.notifier).state =
          updateInfo?.hasNewVersion ?? false;
      ref.read(showUpdateRedDotProvider.notifier).state = false;

      if (updateInfo != null && updateInfo.hasNewVersion) {
        await updateService.markAsNotified(channel: channel);
        if (!mounted || channelRevision != updateService.channelRevision) {
          return;
        }
        _showUpdateDialog(updateInfo);
      } else if (channel == UpdateChannel.beta && updateInfo == null) {
        SnackBarUtil.showInfo(context, S.of(context).noBetaRelease);
      } else {
        SnackBarUtil.showInfo(context, S.of(context).alreadyLatestVersion);
      }
    } catch (error) {
      if (!mounted || channelRevision != updateService.channelRevision) return;
      SnackBarUtil.showError(context, S.of(context).checkUpdateFailed);
    } finally {
      if (mounted && channelRevision == updateService.channelRevision) {
        setState(() => _isCheckingUpdate = false);
      }
    }
  }

  String _updateChannelLabel(BuildContext context, UpdateChannel channel) =>
      channel == UpdateChannel.beta
      ? S.of(context).betaUpdateChannel
      : S.of(context).stableUpdateChannel;

  Future<void> _showUpdateChannelDialog(
    UpdateChannel selectedChannel, {
    required bool isAndroid,
  }) async {
    final channel = await showDialog<UpdateChannel>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(S.of(dialogContext).updateChannel),
        content: RadioGroup<UpdateChannel>(
          groupValue: selectedChannel,
          onChanged: (channel) {
            if (channel != null) Navigator.of(dialogContext).pop(channel);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<UpdateChannel>(
                key: const ValueKey('stable-update-channel'),
                value: UpdateChannel.stable,
                title: Text(S.of(dialogContext).stableUpdateChannel),
              ),
              RadioListTile<UpdateChannel>(
                key: const ValueKey('beta-update-channel'),
                value: UpdateChannel.beta,
                enabled: isAndroid,
                title: Text(S.of(dialogContext).betaUpdateChannel),
                subtitle: isAndroid
                    ? null
                    : Text(S.of(dialogContext).betaOnlyAndroid),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(S.of(dialogContext).close),
          ),
        ],
      ),
    );

    if (channel == null || channel == selectedChannel || !mounted) return;
    final updateService = ref.read(updateServiceProvider);
    final updateInfo = ref.read(updateInfoProvider.notifier);
    final hasNewVersion = ref.read(hasNewVersionProvider.notifier);
    final showRedDot = ref.read(showUpdateRedDotProvider.notifier);
    final updateController = ref.read(updateControllerProvider.notifier);
    updateInfo.state = null;
    hasNewVersion.state = false;
    showRedDot.state = false;
    updateController.reset();
    await updateService.setUpdateChannel(channel);
    if (!mounted) return;
    setState(() => _selectedUpdateChannel = channel);
    await _checkUpdates(allowConcurrent: true);
  }

  void _showUpdateDialog(UpdateInfo updateInfo) {
    showDialog<void>(
      context: context,
      builder: (context) => UpdateDialog(updateInfo: updateInfo),
    );
  }

  void _showLicenseDialog(String license) {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(S.of(context).openSourceLicense),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(child: SelectableText(license)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(S.of(context).close),
            ),
          ],
        );
      },
    );
  }
}

class _AboutData {
  final String version;
  final String buildNumber;
  final String license;
  final UpdateChannel updateChannel;

  const _AboutData({
    required this.version,
    required this.buildNumber,
    required this.license,
    required this.updateChannel,
  });
}
