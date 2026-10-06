import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/file_preview_resolver.dart';
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/work_resource_tabs.dart';

List<dynamic> _files({bool images = false}) => [
  {
    'type': 'folder',
    'title': 'A',
    'children': [
      {'type': 'audio', 'title': 'track01.wav', 'hash': 'audio1'},
      {'type': 'audio', 'title': 'track01.mp3', 'hash': 'mp3'},
    ],
  },
  {
    'type': 'folder',
    'title': 'B',
    'children': [
      {'type': 'audio', 'title': 'track02.wav', 'hash': 'audio2'},
    ],
  },
  {
    'type': 'folder',
    'title': 'Captions',
    'children': [
      {'type': 'text', 'title': 'track01.srt', 'hash': 'subtitle1'},
      {'type': 'text', 'title': 'track01.lrc', 'hash': 'subtitle2'},
      {'type': 'text', 'title': 'notes.txt', 'hash': 'notes'},
    ],
  },
  if (images) ...[
    {'type': 'image', 'title': 'one.png', 'hash': 'image1'},
    {
      'type': 'folder',
      'title': 'Artwork',
      'children': [
        {'type': 'image', 'title': 'two.png', 'hash': 'image2'},
      ],
    },
  ],
];

Future<void> _pumpResources(
  WidgetTester tester,
  ValueNotifier<List<dynamic>> tree, {
  ResourceAudioAction? onPlay,
  void Function(dynamic, String, String)? onFileTap,
  ValueChanged<dynamic>? onImageTap,
  Future<PreviewFileItem?> Function(dynamic)? resolveImage,
  Map<String, bool> downloadedFiles = const {},
}) => tester.pumpWidget(
  ProviderScope(
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      home: Scaffold(
        body: ValueListenableBuilder<List<dynamic>>(
          valueListenable: tree,
          builder: (context, files, _) => CustomScrollView(
            slivers: [
              WorkResourceTabs(
                workId: 42,
                fileTree: files,
                audioVariants: const PlayerAudioVariantClassifier().scan(files),
                resourceSliver: const SliverToBoxAdapter(
                  child: Text('whole resource tree'),
                ),
                resourceTitle: 'Resource Files',
                onPlayAudio: onPlay ?? (_, __, ___) {},
                onFileTap: onFileTap ?? (_, __, ___) {},
                onImageTap: onImageTap ?? (_) {},
                resolveImage: resolveImage ?? (_) async => null,
                downloadedFiles: downloadedFiles,
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets('download changes refresh image targets with the same tree', (
    tester,
  ) async {
    final tree = ValueNotifier(_files(images: true));
    addTearDown(tree.dispose);
    final downloaded = {'image1': true};
    var imageLoads = 0;
    Future<PreviewFileItem?> resolve(dynamic file) async {
      if (file['hash'] == 'image1') imageLoads++;
      return null;
    }

    await _pumpResources(
      tester,
      tree,
      downloadedFiles: downloaded,
      resolveImage: resolve,
    );
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pumpAndSettle();
    expect(imageLoads, 1);
    downloaded['image1'] = false;
    await _pumpResources(
      tester,
      tree,
      downloadedFiles: downloaded,
      resolveImage: resolve,
    );
    await tester.pumpAndSettle();
    expect(imageLoads, 2);
  });

  testWidgets(
    'defaults to preferred audio and only shows the best work subtitle',
    (tester) async {
      final tree = ValueNotifier(_files());
      addTearDown(tree.dispose);
      List<dynamic>? queue;
      dynamic selected;
      String? subtitlePath;
      await _pumpResources(
        tester,
        tree,
        onPlay: (file, path, files) {
          selected = file;
          queue = files;
        },
        onFileTap: (_, __, path) => subtitlePath = path,
      );
      await tester.pumpAndSettle();
      expect(find.text('track01.wav'), findsOneWidget);
      expect(find.text('track02.wav'), findsOneWidget);
      expect(find.text('track01.mp3'), findsNothing);
      expect(find.text('track01.lrc'), findsOneWidget);
      expect(find.text('track01.srt'), findsNothing);
      expect(find.text('notes.txt'), findsNothing);
      expect(find.text('whole resource tree'), findsNothing);
      expect(
        find.byKey(const ValueKey('work-resource-images-tab')),
        findsNothing,
      );
      await tester.tap(find.text('track02.wav'));
      expect(selected['hash'], 'audio2');
      expect(queue!.map((file) => file['hash']), ['audio1', 'audio2']);
      await tester.tap(find.text('track01.lrc'));
      expect(subtitlePath, 'Captions');

      final container = ProviderScope.containerOf(
        tester.element(find.byType(WorkResourceTabs)),
      );
      await container
          .read(audioFormatPreferenceProvider.notifier)
          .updatePreference(
            const AudioFormatPreference(
              priority: [AudioFormat.mp3, AudioFormat.wav],
            ),
          );
      await tester.pumpAndSettle();
      expect(find.text('track01.mp3'), findsOneWidget);
      expect(find.text('track01.wav'), findsNothing);
      expect(find.text('track02.wav'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
      await tester.pumpAndSettle();
      expect(find.text('whole resource tree'), findsOneWidget);
    },
  );

  testWidgets('empty audio tab stays available', (tester) async {
    final tree = ValueNotifier<List<dynamic>>([
      {'type': 'text', 'title': 'notes.txt', 'hash': 'notes'},
    ]);
    addTearDown(tree.dispose);
    await _pumpResources(tester, tree);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('work-resource-audio-tab')),
      findsOneWidget,
    );
    expect(find.text('No playable audio files found'), findsOneWidget);
  });

  testWidgets(
    'images use all resource images and fall back to audio after refresh',
    (tester) async {
      final tree = ValueNotifier(_files(images: true));
      addTearDown(tree.dispose);
      dynamic selected;
      await _pumpResources(tester, tree, onImageTap: (file) => selected = file);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
      await tester.pumpAndSettle();
      expect(find.text('one.png'), findsOneWidget);
      expect(find.text('two.png'), findsOneWidget);
      await tester.tap(find.text('two.png'));
      expect(selected['hash'], 'image2');
      tree.value = _files();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('work-resource-images-tab')),
        findsNothing,
      );
      expect(find.text('track01.wav'), findsOneWidget);
      final tabs = tester.widget<TabBar>(find.byType(TabBar));
      expect(
        DefaultTabController.of(tester.element(find.byWidget(tabs))).index,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('image target errors can retry on narrow and wide layouts', (
    tester,
  ) async {
    for (final width in [390.0, 1200.0]) {
      await tester.binding.setSurfaceSize(Size(width, 844));
      final tree = ValueNotifier(_files(images: true));
      var attempts = 0;
      await _pumpResources(
        tester,
        tree,
        resolveImage: (_) async {
          attempts++;
          throw StateError('unavailable');
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      await tester.tap(find.byTooltip('Retry').first);
      await tester.pumpAndSettle();
      expect(attempts, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      tree.dispose();
    }
    await tester.binding.setSurfaceSize(null);
  });
}
