import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../l10n/app_localizations.dart';
import '../../providers/works_provider.dart' show LayoutType;
import '../../services/storage_service.dart';
import '../../widgets/settings_section.dart';
import '../../widgets/radio_option_group.dart';
import '../../widgets/settings_option_dialog.dart';
import '../../utils/snackbar_util.dart';
import '../comic_models.dart';
import '../comic_providers.dart';
import '../comic_images.dart';
import '../comic_source.dart';

String comicModeLabel(S s, ComicReadingMode mode) => [
  s.comicModeLtr,
  s.comicModeRtl,
  s.comicModeVertical,
  s.comicModeContinuous,
  s.comicModeSpread,
  s.comicModeReverseSpread,
][mode.index];

class ComicSettingsScreen extends ConsumerWidget {
  const ComicSettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(comicSettingsRevisionProvider);
    final s = S.of(context);
    final layout = ref.watch(comicLayoutProvider);
    final pageSize = ref.watch(comicPageSizeProvider);
    Future<void> save(String key, bool value) async {
      await StorageService.setBool(key, value);
      ref.read(comicSettingsRevisionProvider.notifier).state++;
    }

    return SettingsSubpageScaffold(
      title: s.comicSettings,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(s.comicSources, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SettingsSectionList(
            children: [
              for (final source in ref.watch(comicSourcesProvider))
                SettingsNavigationTile(
                  icon: Icons.public,
                  title: source.name,
                  subtitle: source.isLoggedIn
                      ? s.accountManagement
                      : s.comicAnonymous,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ComicSourceSettingsScreen(source: source),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(s.comicReader, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SettingsSectionList(
            children: [
              SettingsNavigationTile(
                icon: Icons.chrome_reader_mode,
                title: s.comicReadingMode,
                subtitle: comicModeLabel(
                  s,
                  ref.watch(comicReadingModeProvider),
                ),
                onTap: () async {
                  final selected = await showDialog<ComicReadingMode>(
                    context: context,
                    builder: (context) => SimpleDialog(
                      title: Text(s.comicReadingMode),
                      children: [
                        for (final mode in ComicReadingMode.values)
                          SimpleDialogOption(
                            onPressed: () => Navigator.pop(context, mode),
                            child: Text(comicModeLabel(s, mode)),
                          ),
                      ],
                    ),
                  );
                  if (selected != null) {
                    ref.read(comicReadingModeProvider.notifier).state =
                        selected;
                    await StorageService.setString(
                      'comic_reading_mode',
                      selected.name,
                    );
                  }
                },
              ),
              SettingsSwitchTile(
                title: s.comicTapToTurn,
                icon: Icons.touch_app_outlined,
                value: StorageService.getBool('comic_tap_to_turn') ?? true,
                onChanged: (v) => save('comic_tap_to_turn', v),
              ),
              SettingsSwitchTile(
                title: s.comicDoubleTapZoom,
                icon: Icons.zoom_in,
                value: StorageService.getBool('comic_double_tap_zoom') ?? true,
                onChanged: (v) => save('comic_double_tap_zoom', v),
              ),
              SettingsSwitchTile(
                title: s.comicKeepAwake,
                icon: Icons.light_mode_outlined,
                value: StorageService.getBool('comic_keep_awake') ?? true,
                onChanged: (v) => save('comic_keep_awake', v),
              ),
              SettingsNavigationTile(
                title: s.comicPreload,
                icon: Icons.layers_outlined,
                subtitle: '${StorageService.getInt('comic_preload') ?? 3}',
                onTap: () async {
                  final selected = await showDialog<int>(
                    context: context,
                    builder: (context) => SimpleDialog(
                      title: Text(s.comicPreload),
                      children: [
                        for (final count in [0, 1, 3, 5, 10])
                          SimpleDialogOption(
                            onPressed: () => Navigator.pop(context, count),
                            child: Text('$count'),
                          ),
                      ],
                    ),
                  );
                  if (selected != null) {
                    await StorageService.setInt('comic_preload', selected);
                    ref.read(comicSettingsRevisionProvider.notifier).state++;
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          SettingsSectionList(
            children: [
              SettingsSwitchTile(
                title: s.comicDefaultOnlineFavorites,
                icon: Icons.cloud_outlined,
                value:
                    StorageService.getBool('comic_online_favorites') ?? false,
                onChanged: (v) => save('comic_online_favorites', v),
              ),
              SettingsNavigationTile(
                icon: Icons.format_list_numbered,
                title: s.pageSizeSettings,
                subtitle: s.pageSizeCurrent(pageSize),
                trailingIconSize: 16,
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (dialogContext) => CommonOptionDialog<int>(
                    title: S.of(dialogContext).pageSizeSettings,
                    icon: Icons.format_list_numbered,
                    value: pageSize,
                    options: [
                      for (final size in ComicPageSizeNotifier.options)
                        RadioOption(value: size, title: Text('$size')),
                    ],
                    onChanged: (size) {
                      ref
                          .read(comicPageSizeProvider.notifier)
                          .setPageSize(size);
                      return true;
                    },
                  ),
                ),
              ),
              SettingsNavigationTile(
                icon: Icons.grid_view,
                title: s.layout,
                subtitle: switch (layout) {
                  LayoutType.bigGrid => s.layoutBigGrid,
                  LayoutType.smallGrid => s.layoutSmallGrid,
                  LayoutType.list => s.layoutList,
                },
                onTap: () async {
                  final selected = await showDialog<LayoutType>(
                    context: context,
                    builder: (context) => SimpleDialog(
                      title: Text(s.layout),
                      children: [
                        for (final (value, label) in [
                          (LayoutType.bigGrid, s.layoutBigGrid),
                          (LayoutType.smallGrid, s.layoutSmallGrid),
                          (LayoutType.list, s.layoutList),
                        ])
                          SimpleDialogOption(
                            onPressed: () => Navigator.pop(context, value),
                            child: Row(
                              children: [
                                Icon(
                                  layout == value
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                ),
                                const SizedBox(width: 12),
                                Text(label),
                              ],
                            ),
                          ),
                      ],
                    ),
                  );
                  if (selected != null) {
                    ref.read(comicLayoutProvider.notifier).set(selected);
                  }
                },
              ),
              SettingsNavigationTile(
                icon: Icons.folder_outlined,
                title: s.downloadPath,
                subtitle: StorageService.getString('comic_download_directory'),
                onTap: () async {
                  final directory = await FilePicker.platform
                      .getDirectoryPath();
                  if (directory != null) {
                    await StorageService.setString(
                      'comic_download_directory',
                      directory,
                    );
                    ref.read(comicSettingsRevisionProvider.notifier).state++;
                  }
                },
              ),
              SettingsNavigationTile(
                icon: Icons.cleaning_services_outlined,
                title: s.comicClearCache,
                onTap: () async {
                  await comicImageCache.emptyCache();
                  if (context.mounted) {
                    SnackBarUtil.showSuccess(context, s.comicSaved);
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class ComicSourceSettingsScreen extends ConsumerStatefulWidget {
  const ComicSourceSettingsScreen({super.key, required this.source});
  final ComicSource source;
  @override
  ConsumerState<ComicSourceSettingsScreen> createState() =>
      _ComicSourceSettingsScreenState();
}

class _ComicSourceSettingsScreenState
    extends ConsumerState<ComicSourceSettingsScreen> {
  final _username = TextEditingController(),
      _password = TextEditingController(),
      _cookie = TextEditingController(),
      _token = TextEditingController();
  late final _endpoint = TextEditingController(text: widget.source.website);
  bool _busy = false;
  Object? _error;
  @override
  void dispose() {
    for (final c in [_username, _password, _cookie, _token, _endpoint]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _action(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) {
        ref.read(comicSettingsRevisionProvider.notifier).state++;
        SnackBarUtil.showSuccess(context, S.of(context).comicSaved);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final s = S.of(context);
    return SettingsSubpageScaffold(
      title: source.name,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SettingsSwitchTile(
            title: s.comicEnabled,
            value:
                StorageService.getBool('comic_${source.key}_enabled') ?? true,
            onChanged: (value) => _action(
              () =>
                  StorageService.setBool('comic_${source.key}_enabled', value),
            ),
          ),
          if (['ehentai', 'htmanga', 'jmcomic'].contains(source.key)) ...[
            TextField(
              controller: _endpoint,
              decoration: InputDecoration(labelText: s.comicEndpoint),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _action(() async {
                      final uri = Uri.tryParse(_endpoint.text.trim());
                      if (uri == null ||
                          !['http', 'https'].contains(uri.scheme) ||
                          uri.host.isEmpty) {
                        throw const FormatException('Invalid website URL');
                      }
                      await StorageService.setString(
                        'comic_${source.key}_endpoint',
                        uri.toString().replaceFirst(RegExp(r'/+$'), ''),
                      );
                    }),
              child: Text(s.save),
            ),
          ],
          if (source.hasAccount) ...[
            if (source.hasPasswordLogin) ...[
              TextField(
                controller: _username,
                autofillHints: const [AutofillHints.username],
                decoration: InputDecoration(labelText: s.comicUsername),
              ),
              TextField(
                controller: _password,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(labelText: s.comicPassword),
              ),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _action(
                        () =>
                            source.login(_username.text.trim(), _password.text),
                      ),
                child: Text(s.comicLogin),
              ),
            ],
            TextButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(
                  source.key == 'ehentai'
                      ? 'https://forums.e-hentai.org/index.php?act=Login&CODE=00'
                      : source.website,
                ),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new),
              label: Text(s.comicOpenWebsite),
            ),
            Text(s.comicCookiesHelp),
            TextField(
              controller: _cookie,
              obscureText: true,
              decoration: InputDecoration(labelText: s.comicSessionCookie),
            ),
            if (source.key == 'picacg' || source.key == 'nhentai')
              TextField(
                controller: _token,
                obscureText: true,
                decoration: InputDecoration(labelText: s.comicSessionToken),
              ),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _action(() async {
                      if (_cookie.text.trim().isEmpty &&
                          _token.text.trim().isEmpty) {
                        return;
                      }
                      await source.http.saveSession(
                        cookie: _cookie.text.trim().isEmpty
                            ? null
                            : _cookie.text.trim(),
                        token: _token.text.trim().isEmpty
                            ? null
                            : _token.text.trim(),
                      );
                      _cookie.clear();
                      _token.clear();
                    }),
              child: Text(s.save),
            ),
            TextButton(
              onPressed: _busy ? null : () => _action(source.logout),
              child: Text(s.comicLogout),
            ),
          ],
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '$_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
