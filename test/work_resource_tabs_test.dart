import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/file_preview_resolver.dart';
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/work_resource_tabs.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_cover_frame.dart';
import 'package:kikoeru_flutter/src/utils/local_file_url.dart';

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
  Set<String> expandedFolders = const {},
  ValueChanged<List<String>>? onVisibleNamesChanged,
  ScrollController? controller,
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
            controller: controller,
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
                expandedFolders: expandedFolders,
                onVisibleNamesChanged: onVisibleNamesChanged,
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

Future<void> _waitForImage(WidgetTester tester, Finder finder) async {
  final image = tester.widget<Image>(finder);
  final configuration = createLocalImageConfiguration(tester.element(finder));
  await tester.runAsync(() async {
    final stream = image.image.resolve(configuration);
    final loaded = Completer<void>();
    final listener = ImageStreamListener(
      (_, __) {
        if (!loaded.isCompleted) loaded.complete();
      },
      onError: (error, stackTrace) {
        if (!loaded.isCompleted) loaded.completeError(error, stackTrace);
      },
    );
    stream.addListener(listener);
    try {
      await loaded.future.timeout(const Duration(seconds: 5));
    } finally {
      stream.removeListener(listener);
    }
  });
}

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

  testWidgets('image cards keep their aspect ratio after scrolling back', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = Directory.systemTemp.createTempSync(
      'work-resource-images-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final imageFiles = <String, File>{};
    final files = List<dynamic>.generate(12, (index) {
      final hash = 'image$index';
      final file = File('${directory.path}/$hash.png')
        ..writeAsBytesSync(
          img.encodePng(
            img.Image(
              width: index == 0 ? 80 : 160,
              height: index == 0 ? 160 : 80,
            ),
          ),
        );
      imageFiles[hash] = file;
      return {'type': 'image', 'title': '$hash.png', 'hash': hash};
    });
    final tree = ValueNotifier<List<dynamic>>(files);
    addTearDown(tree.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _pumpResources(
      tester,
      tree,
      controller: controller,
      resolveImage: (file) async {
        final hash = file['hash'] as String;
        return PreviewFileItem(
          url: LocalFileUrl.fromPath(imageFiles[hash]!.path),
          title: file['title'] as String,
          hash: hash,
        );
      },
    );
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pump();
    await tester.pump();

    Finder firstCard() => find.ancestor(
      of: find.text('image0.png'),
      matching: find.byType(Card),
    );

    final initialCard = firstCard();
    final initialImage = find.descendant(
      of: initialCard,
      matching: find.byType(Image),
    );
    expect(initialImage, findsOneWidget);
    await _waitForImage(tester, initialImage);
    await tester.pump();
    final initialCardHeight = tester.getRect(initialCard).height;
    expect(
      tester.getRect(initialImage).width / tester.getRect(initialImage).height,
      closeTo(0.5, 0.01),
    );

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(firstCard(), findsNothing);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    controller.jumpTo(0);
    await tester.pump();

    final returnedCard = firstCard();
    expect(returnedCard, findsOneWidget);
    expect(tester.getRect(returnedCard).height, closeTo(initialCardHeight, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'defaults to preferred audio with an eye for the best work subtitle',
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
      expect(find.text('track01.lrc'), findsNothing);
      expect(find.text('track01.srt'), findsNothing);
      expect(find.byIcon(Icons.subtitles_outlined), findsNothing);
      expect(find.text('notes.txt'), findsNothing);
      expect(find.text('whole resource tree'), findsNothing);
      expect(
        find.byKey(const ValueKey('work-resource-images-tab')),
        findsNothing,
      );
      await tester.tap(find.text('track02.wav'));
      expect(selected['hash'], 'audio2');
      expect(queue!.map((file) => file['hash']), ['audio1', 'audio2']);
      await tester.tap(
        find.byKey(const ValueKey('work-audio-subtitle-A/track01.wav')),
      );
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

  testWidgets('reports only names in the current tab and expanded folders', (
    tester,
  ) async {
    final tree = ValueNotifier(_files(images: true));
    addTearDown(tree.dispose);
    final reports = <List<String>>[];
    final expanded = <String>{};
    await _pumpResources(
      tester,
      tree,
      expandedFolders: expanded,
      onVisibleNamesChanged: reports.add,
    );
    await tester.pumpAndSettle();
    expect(reports.last, ['track01.wav', 'track02.wav']);
    await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
    await tester.pumpAndSettle();
    expect(reports.last, ['A', 'B', 'Captions', 'one.png', 'Artwork']);
    expanded.add('Artwork');
    await _pumpResources(
      tester,
      tree,
      expandedFolders: expanded,
      onVisibleNamesChanged: reports.add,
    );
    await tester.pumpAndSettle();
    expect(reports.last, [
      'A',
      'B',
      'Captions',
      'one.png',
      'Artwork',
      'two.png',
    ]);
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pumpAndSettle();
    expect(reports.last, ['one.png', 'two.png']);
    await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
    await tester.pumpAndSettle();
    expect(reports.last.last, 'two.png');
    final reportCount = reports.length;
    await _pumpResources(
      tester,
      tree,
      expandedFolders: expanded,
      onVisibleNamesChanged: reports.add,
    );
    await tester.pumpAndSettle();
    expect(reports.length, reportCount);
  });

  testWidgets('audio uses tree typography and colors and full content width', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final width in [390.0, 1200.0]) {
      await tester.binding.setSurfaceSize(Size(width, 844));
      final tree = ValueNotifier(_files());
      await _pumpResources(tester, tree);
      await tester.pumpAndSettle();
      final audio = find.byKey(const ValueKey('work-audio-A/track01.wav'));
      final tile = tester.widget<ListTile>(audio);
      expect((tile.leading! as Icon).color, Colors.green);
      expect((tile.title! as Text).style!.fontSize, 14);
      expect(tester.getRect(audio).width, width);
      expect(tester.getRect(find.byIcon(Icons.audiotrack).first).left, 0);
      expect(tester.getRect(find.text('Resource Files')).left, 16);
      final play = find.descendant(
        of: audio,
        matching: find.byIcon(Icons.play_arrow),
      );
      final eye = find.descendant(
        of: audio,
        matching: find.byIcon(Icons.visibility),
      );
      expect(tester.widget<Icon>(play).color, Colors.green);
      expect(tester.getRect(eye).left, greaterThan(tester.getRect(play).left));
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(of: eye, matching: find.byType(IconButton)),
            )
            .color,
        Colors.blue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      tree.dispose();
    }
  });

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
      final clips = tester.widgetList<ClipRRect>(
        find.descendant(
          of: find.byType(WorkCoverClip),
          matching: find.byType(ClipRRect),
        ),
      );
      expect(clips, hasLength(2));
      for (final clip in clips) {
        expect(
          clip.borderRadius,
          BorderRadius.circular(workCoverCompactRadius),
        );
      }
      expect(tester.getRect(find.byType(Card).first).left, 0);
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
      expect(
        tester.getRect(find.byType(Card).first).top -
            tester.getRect(find.byType(TabBar)).bottom,
        8,
      );
      expect(tester.getRect(find.byType(Card).first).left, 0);
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
