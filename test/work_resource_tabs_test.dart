import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/providers/work_detail_display_provider.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/file_preview_resolver.dart';
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/local_file_url.dart';
import 'package:kikoeru_flutter/src/widgets/cached_image_widget.dart';
import 'package:kikoeru_flutter/src/widgets/pagination_bar.dart';
import 'package:kikoeru_flutter/src/widgets/work_resource_tabs.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_cover_frame.dart';

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

List<dynamic> _audioFiles(int count, {bool images = false}) => [
  for (var index = 0; index < count; index++)
    {'type': 'audio', 'title': 'track$index.wav', 'hash': 'audio$index'},
  if (images) {'type': 'image', 'title': 'one.png', 'hash': 'image1'},
  if (images) {'type': 'image', 'title': 'two.png', 'hash': 'image2'},
];

class _RecommendationProbe extends StatefulWidget {
  const _RecommendationProbe({required this.onCreate});

  final VoidCallback onCreate;

  @override
  State<_RecommendationProbe> createState() => _RecommendationProbeState();
}

class _RecommendationProbeState extends State<_RecommendationProbe> {
  @override
  void initState() {
    super.initState();
    widget.onCreate();
  }

  @override
  Widget build(BuildContext context) =>
      const SliverToBoxAdapter(child: Text('recommendation page content'));
}

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
  bool disableAnimations = false,
  int recommendationCount = 0,
  WidgetBuilder? recommendationBuilder,
  Widget? introSliver,
  Widget? resourceSliver,
  String? progressMessage,
  Locale locale = const Locale('en'),
  WorkResourceTab initialTab = WorkResourceTab.audio,
  ProviderContainer? providerContainer,
}) async {
  final recommendation =
      recommendationBuilder ??
      (recommendationCount == 0
          ? null
          : (context) => SliverList.builder(
              itemCount: recommendationCount,
              itemBuilder: (context, index) =>
                  SizedBox(height: 70, child: Text('recommendation $index')),
            ));
  final app = MaterialApp(
    locale: locale,
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: disableAnimations),
          child: ValueListenableBuilder<List<dynamic>>(
            valueListenable: tree,
            builder: (context, files, _) => CustomScrollView(
              controller: controller,
              slivers: [
                if (introSliver != null) introSliver,
                WorkResourceTabs(
                  workId: 42,
                  fileTree: files,
                  audioVariants: const PlayerAudioVariantClassifier().scan(
                    files,
                  ),
                  resourceSliver:
                      resourceSliver ??
                      const SliverToBoxAdapter(
                        child: Text('whole resource tree'),
                      ),
                  resourceTitle: S.of(context).workResources,
                  recommendationBuilder: recommendation,
                  progressMessage: progressMessage,
                  initialTab: initialTab,
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
  await tester.pumpWidget(
    providerContainer == null
        ? ProviderScope(child: app)
        : UncontrolledProviderScope(container: providerContainer, child: app),
  );
}

Future<void> _pumpUntilImageLoaded(WidgetTester tester, Finder finder) async {
  final rawImage = find.descendant(of: finder, matching: find.byType(RawImage));
  expect(rawImage, findsOneWidget);
  for (
    var frame = 0;
    frame < 100 && tester.widget<RawImage>(rawImage).image == null;
    frame++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(tester.widget<RawImage>(rawImage).image, isNotNull);
}

Finder _loadingOverlaySpinner() => find.byKey(
  const ValueKey('work-resource-images-loading'),
  skipOffstage: false,
);

String _firstVisibleNumberedText(
  WidgetTester tester, {
  required String prefix,
  required String suffix,
  required int count,
}) {
  for (var index = 0; index < count; index++) {
    final title = '$prefix$index$suffix';
    final finder = find.text(title);
    if (finder.evaluate().isEmpty) continue;
    final rect = tester.getRect(finder);
    if (rect.top >= 60 && rect.bottom <= 500) return title;
  }
  throw TestFailure('No visible title matched "$prefix…$suffix"');
}

double _textTop(WidgetTester tester, String title) =>
    tester.getTopLeft(find.text(title)).dy;

Future<void> _tapWithoutPump(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(tester.getCenter(finder));
  await gesture.up();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('unvisited resource tabs start at the section top', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tree = ValueNotifier<List<dynamic>>(_files());
    final scroll = ScrollController();
    addTearDown(tree.dispose);
    addTearDown(scroll.dispose);

    await _pumpResources(
      tester,
      tree,
      controller: scroll,
      introSliver: const SliverToBoxAdapter(
        child: SizedBox(height: 180, child: Text('work introduction')),
      ),
      resourceSliver: SliverList.builder(
        itemCount: 36,
        itemBuilder: (context, index) =>
            SizedBox(height: 48, child: Text('resource item $index')),
      ),
      recommendationCount: 12,
    );

    await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(180, 1));
    expect(tester.getTopLeft(find.byType(TabBar)).dy, closeTo(0, 1));

    scroll.jumpTo(scroll.offset + 500);
    await tester.pump();
    expect(tester.getTopLeft(find.byType(TabBar)).dy, closeTo(0, 1));
    final sourceOffset = scroll.offset;

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('resource item 12')),
    );
    await gesture.moveBy(const Offset(-430, 0));
    await tester.pump();
    expect(scroll.offset, closeTo(sourceOffset, 1));
    expect(tester.getTopLeft(find.byType(TabBar)).dy, closeTo(0, 1));
    expect(find.text('recommendation 11'), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(scroll.offset, closeTo(180, 1));
    expect(tester.getTopLeft(find.byType(TabBar)).dy, closeTo(0, 1));
    expect(find.text('recommendation 11'), findsNothing);

    await tester.ensureVisible(
      find.byKey(const ValueKey('work-resource-recommendations-tab')),
    );
    await tester.tap(
      find.byKey(const ValueKey('work-resource-recommendations-tab')),
    );
    await tester.pumpAndSettle();
    expect(find.text('recommendation 0'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('recommendation 11'),
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 10,
    );
    expect(find.text('recommendation 11'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final shortPage in [false, true]) {
    testWidgets('swiping keeps an unpinned tab bar in place ($shortPage)', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final tree = ValueNotifier<List<dynamic>>(_audioFiles(40));
      final scroll = ScrollController();
      addTearDown(tree.dispose);
      addTearDown(scroll.dispose);
      await _pumpResources(
        tester,
        tree,
        controller: scroll,
        introSliver: const SliverToBoxAdapter(child: SizedBox(height: 180)),
        resourceSliver: shortPage
            ? const SliverToBoxAdapter(child: Text('short resource page'))
            : SliverList.builder(
                itemCount: 40,
                itemBuilder: (context, index) =>
                    SizedBox(height: 48, child: Text('resource item $index')),
              ),
      );
      if (!shortPage) {
        await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
        await tester.pumpAndSettle();
        scroll.jumpTo(600);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('work-resource-audio-tab')));
        await tester.pumpAndSettle();
      }
      scroll.jumpTo(80);
      await tester.pump();
      final barTop = tester.getTopLeft(find.byType(TabBar)).dy;
      expect(barTop, closeTo(100, 1));

      final gesture = await tester.startGesture(const Offset(195, 300));
      await gesture.moveBy(const Offset(230, 0));
      await tester.pump();
      expect(scroll.offset, closeTo(80, 1));
      expect(tester.getTopLeft(find.byType(TabBar)).dy, closeTo(barTop, 1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(80, 1));
      expect(tester.getTopLeft(find.byType(TabBar)).dy, closeTo(barTop, 1));
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);

      final canceled = await tester.startGesture(const Offset(195, 300));
      await canceled.moveBy(const Offset(-60, 0));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      await canceled.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(80, 1));
      expect(tester.getTopLeft(find.byType(TabBar)).dy, closeTo(barTop, 1));
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'resource tabs restore independent offsets across taps and swipes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final tree = ValueNotifier<List<dynamic>>(_audioFiles(40));
      final scroll = ScrollController();
      addTearDown(tree.dispose);
      addTearDown(scroll.dispose);

      await _pumpResources(
        tester,
        tree,
        controller: scroll,
        introSliver: const SliverToBoxAdapter(
          child: SizedBox(height: 180, child: Text('work introduction')),
        ),
        resourceSliver: SliverList.builder(
          itemCount: 40,
          itemBuilder: (context, index) =>
              SizedBox(height: 48, child: Text('resource item $index')),
        ),
        recommendationCount: 40,
      );

      scroll.jumpTo(450);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(180, 1));

      scroll.jumpTo(600);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(600, 1));

      await tester.tap(
        find.byKey(const ValueKey('work-resource-recommendations-tab')),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(180, 1));
      scroll.jumpTo(700);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('work-resource-audio-tab')));
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(450, 1));

      await tester.tap(
        find.byKey(const ValueKey('work-resource-recommendations-tab')),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(700, 1));

      final swipeToAudio = await tester.startGesture(const Offset(195, 250));
      await swipeToAudio.moveBy(const Offset(200, 0));
      await tester.pump();
      await swipeToAudio.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(450, 1));

      final swipeToResources = await tester.startGesture(
        const Offset(195, 250),
      );
      await swipeToResources.moveBy(const Offset(200, 0));
      await tester.pump();
      await swipeToResources.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(600, 1));

      final canceledSwipe = await tester.startGesture(const Offset(195, 250));
      await canceledSwipe.moveBy(const Offset(-60, 0));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      await canceledSwipe.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(600, 1));
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a short unvisited page cannot overwrite a long page offset', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tree = ValueNotifier<List<dynamic>>(_audioFiles(40, images: true));
    final scroll = ScrollController();
    addTearDown(tree.dispose);
    addTearDown(scroll.dispose);

    await _pumpResources(
      tester,
      tree,
      controller: scroll,
      introSliver: const SliverToBoxAdapter(
        child: SizedBox(height: 80, child: Text('work introduction')),
      ),
      resourceSliver: SliverList.builder(
        itemCount: 40,
        itemBuilder: (context, index) =>
            SizedBox(height: 48, child: Text('resource item $index')),
      ),
    );

    scroll.jumpTo(450);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pumpAndSettle();
    expect(scroll.offset, lessThan(450));

    await tester.tap(find.byKey(const ValueKey('work-resource-audio-tab')));
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(450, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unpulled tab taps show the target at its restored position', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tree = ValueNotifier<List<dynamic>>(_audioFiles(50));
    final scroll = ScrollController();
    var resourceTapped = false;
    addTearDown(tree.dispose);
    addTearDown(scroll.dispose);

    await _pumpResources(
      tester,
      tree,
      controller: scroll,
      introSliver: const SliverToBoxAdapter(
        child: SizedBox(height: 180, child: Text('work introduction')),
      ),
      resourceSliver: SliverList.builder(
        itemCount: 50,
        itemBuilder: (context, index) => GestureDetector(
          onTap: () => resourceTapped = true,
          child: SizedBox(height: 48, child: Text('resource item $index')),
        ),
      ),
      progressMessage: 'Loading resource files',
    );
    scroll.jumpTo(80);
    await tester.pump();
    final audioTitle = _firstVisibleNumberedText(
      tester,
      prefix: 'track',
      suffix: '.wav',
      count: 50,
    );
    final audioTop = _textTop(tester, audioTitle);

    await _tapWithoutPump(
      tester,
      find.byKey(const ValueKey('work-resource-files-tab')),
    );
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text(audioTitle).hitTestable(), findsOneWidget);
    expect(_textTop(tester, audioTitle), closeTo(audioTop, 1));

    double? firstResourceTop;
    const viewport = Rect.fromLTWH(0, 0, 390, 500);
    for (var frame = 0; frame < 30 && firstResourceTop == null; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final visibleAudio = find.text(audioTitle).hitTestable();
      if (visibleAudio.evaluate().isNotEmpty) {
        expect(_textTop(tester, audioTitle), closeTo(audioTop, 1));
      }
      final candidate = find.text('resource item 0', skipOffstage: false);
      if (candidate.evaluate().isNotEmpty) {
        final rect = tester.getRect(candidate.first);
        if (rect.overlaps(viewport)) firstResourceTop = rect.top;
      }
    }
    expect(firstResourceTop, isNotNull);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    final resourceTop = _textTop(tester, 'resource item 0');
    expect(scroll.offset, closeTo(180, 1));
    expect(find.text('Loading resource files'), findsOneWidget);
    expect(resourceTop, closeTo(firstResourceTop!, 1));
    expect(find.text('resource item 0').hitTestable(), findsOneWidget);
    await tester.tap(find.text('resource item 0'));
    expect(resourceTapped, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'each page keeps its content position through tap and swipe frames',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final tree = ValueNotifier<List<dynamic>>(_audioFiles(50));
      final scroll = ScrollController();
      addTearDown(tree.dispose);
      addTearDown(scroll.dispose);

      await _pumpResources(
        tester,
        tree,
        controller: scroll,
        introSliver: const SliverToBoxAdapter(
          child: SizedBox(height: 180, child: Text('work introduction')),
        ),
        resourceSliver: SliverList.builder(
          itemCount: 50,
          itemBuilder: (context, index) =>
              SizedBox(height: 48, child: Text('resource item $index')),
        ),
      );

      scroll.jumpTo(450);
      await tester.pump();
      final audioTitle = _firstVisibleNumberedText(
        tester,
        prefix: 'track',
        suffix: '.wav',
        count: 50,
      );
      final audioTop = _textTop(tester, audioTitle);
      void expectVisibleTop(String title, double expectedTop) {
        final visible = find.text(title).hitTestable();
        if (visible.evaluate().isNotEmpty) {
          expect(_textTop(tester, title), closeTo(expectedTop, 1));
        }
      }

      await _tapWithoutPump(
        tester,
        find.byKey(const ValueKey('work-resource-files-tab')),
      );
      double? firstResourceTop;
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text(audioTitle).hitTestable(), findsOneWidget);
      expect(_textTop(tester, audioTitle), closeTo(audioTop, 1));
      for (final duration in [
        const Duration(milliseconds: 120),
        const Duration(milliseconds: 120),
        const Duration(milliseconds: 120),
      ]) {
        await tester.pump(duration);
        expectVisibleTop(audioTitle, audioTop);
        final visibleResource = find.text('resource item 0').hitTestable();
        if (visibleResource.evaluate().isNotEmpty) {
          final top = _textTop(tester, 'resource item 0');
          firstResourceTop ??= top;
          expect(top, closeTo(firstResourceTop, 1));
        }
      }
      expect(firstResourceTop, isNotNull);
      await tester.pumpAndSettle();
      final resourceTop = _textTop(tester, 'resource item 0');
      expect(
        resourceTop,
        closeTo(tester.getBottomLeft(find.byType(TabBar)).dy, 1),
      );
      if (firstResourceTop != null) {
        expect(resourceTop, closeTo(firstResourceTop, 1));
      }

      scroll.jumpTo(600);
      await tester.pump();
      final resourceTitle = _firstVisibleNumberedText(
        tester,
        prefix: 'resource item ',
        suffix: '',
        count: 50,
      );
      final resourceItemTop = _textTop(tester, resourceTitle);

      await _tapWithoutPump(
        tester,
        find.byKey(const ValueKey('work-resource-audio-tab')),
      );
      double? firstAudioTop;
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text(resourceTitle).hitTestable(), findsOneWidget);
      expect(_textTop(tester, resourceTitle), closeTo(resourceItemTop, 1));
      for (final duration in [
        const Duration(milliseconds: 120),
        const Duration(milliseconds: 120),
        const Duration(milliseconds: 120),
      ]) {
        await tester.pump(duration);
        expectVisibleTop(resourceTitle, resourceItemTop);
        final visibleAudio = find.text(audioTitle).hitTestable();
        if (visibleAudio.evaluate().isNotEmpty) {
          final top = _textTop(tester, audioTitle);
          firstAudioTop ??= top;
          expect(top, closeTo(audioTop, 1));
          expect(top, closeTo(firstAudioTop, 1));
        }
      }
      expect(firstAudioTop, isNotNull);
      await tester.pumpAndSettle();
      expect(_textTop(tester, audioTitle), closeTo(audioTop, 1));

      final swipeToResources = await tester.startGesture(
        tester.getCenter(find.text(audioTitle)),
      );
      await swipeToResources.moveBy(const Offset(70, 0));
      await tester.pump(const Duration(milliseconds: 80));
      expectVisibleTop(audioTitle, audioTop);
      expectVisibleTop(resourceTitle, resourceItemTop);

      await swipeToResources.moveBy(const Offset(170, 0));
      await tester.pump(const Duration(milliseconds: 80));
      expectVisibleTop(audioTitle, audioTop);
      expectVisibleTop(resourceTitle, resourceItemTop);
      await swipeToResources.moveBy(const Offset(80, 0));
      await tester.pump(const Duration(milliseconds: 80));
      await swipeToResources.up();
      await tester.pump(const Duration(milliseconds: 120));
      expectVisibleTop(audioTitle, audioTop);
      expectVisibleTop(resourceTitle, resourceItemTop);
      await tester.pumpAndSettle();
      expect(_textTop(tester, resourceTitle), closeTo(resourceItemTop, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a new swipe cancels a pending reduced-motion offset restore', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tree = ValueNotifier<List<dynamic>>(_audioFiles(40));
    final scroll = ScrollController();
    addTearDown(tree.dispose);
    addTearDown(scroll.dispose);

    await _pumpResources(
      tester,
      tree,
      controller: scroll,
      disableAnimations: true,
      introSliver: const SliverToBoxAdapter(
        child: SizedBox(height: 180, child: Text('work introduction')),
      ),
      resourceSliver: SliverList.builder(
        itemCount: 40,
        itemBuilder: (context, index) =>
            SizedBox(height: 48, child: Text('resource item $index')),
      ),
      recommendationCount: 40,
    );
    scroll.jumpTo(450);
    await tester.pump();

    final selectResources = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('work-resource-files-tab'))),
    );
    await selectResources.up();

    final swipeToAudio = await tester.startGesture(const Offset(195, 250));
    await swipeToAudio.moveBy(const Offset(-270, 0));
    await tester.pump();
    await swipeToAudio.up();

    final selectRecommendations = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('work-resource-recommendations-tab')),
      ),
    );
    await selectRecommendations.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('work-resource-audio-tab')));
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(450, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('resource tabs use equal widths and localized resource labels', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tree = ValueNotifier<List<dynamic>>(_files(images: true));
    addTearDown(tree.dispose);

    await _pumpResources(
      tester,
      tree,
      recommendationBuilder: (_) => const SliverToBoxAdapter(),
    );
    final tabKeys = [
      const ValueKey('work-resource-files-tab'),
      const ValueKey('work-resource-audio-tab'),
      const ValueKey('work-resource-images-tab'),
      const ValueKey('work-resource-recommendations-tab'),
    ];
    final tabs = find.descendant(
      of: find.byType(TabBar),
      matching: find.byType(InkWell),
    );
    expect(tabs, findsNWidgets(tabKeys.length));
    final widths = [
      for (var index = 0; index < tabKeys.length; index++)
        tester.getSize(tabs.at(index)).width,
    ];
    expect(widths, everyElement(closeTo(widths.first, 0.1)));
    expect(find.text('Resources'), findsOneWidget);
    expect(find.text('Related Works'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _pumpResources(
      tester,
      tree,
      locale: const Locale('zh'),
      recommendationBuilder: (_) => const SliverToBoxAdapter(),
    );
    expect(find.text('资源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'recommendations build only after selection and retain their tab identity',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final tree = ValueNotifier<List<dynamic>>(_files());
      addTearDown(tree.dispose);
      var recommendationCreates = 0;
      final display = WorkDetailDisplayNotifier();
      final container = ProviderContainer(
        overrides: [workDetailDisplayProvider.overrideWith((ref) => display)],
      );
      addTearDown(container.dispose);

      await _pumpResources(
        tester,
        tree,
        providerContainer: container,
        recommendationBuilder: (_) =>
            _RecommendationProbe(onCreate: () => recommendationCreates++),
      );
      expect(recommendationCreates, 0);
      expect(
        find.byKey(const ValueKey('work-resource-recommendations-tab')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('work-resource-recommendations-tab')),
      );
      await tester.pumpAndSettle();
      expect(recommendationCreates, 1);
      expect(find.text('recommendation page content'), findsOneWidget);
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 2);

      tree.value = _files(images: true);
      await tester.pumpAndSettle();
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 3);
      expect(recommendationCreates, 1);

      await display.toggleRecommendations();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('work-resource-recommendations-tab')),
        findsNothing,
      );
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 2);

      await display.toggleRecommendations();
      await tester.pumpAndSettle();
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 2);
      await tester.tap(
        find.byKey(const ValueKey('work-resource-recommendations-tab')),
      );
      await tester.pumpAndSettle();
      expect(recommendationCreates, 1);

      tree.value = _files();
      await tester.pumpAndSettle();
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 2);
      expect(recommendationCreates, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hidden recommendation preference removes its tab without building it',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final tree = ValueNotifier<List<dynamic>>(_files(images: true));
      addTearDown(tree.dispose);
      final display = WorkDetailDisplayNotifier();
      await display.toggleRecommendations();
      final container = ProviderContainer(
        overrides: [workDetailDisplayProvider.overrideWith((ref) => display)],
      );
      addTearDown(container.dispose);
      var recommendationCreates = 0;

      await _pumpResources(
        tester,
        tree,
        providerContainer: container,
        recommendationBuilder: (_) =>
            _RecommendationProbe(onCreate: () => recommendationCreates++),
      );
      expect(
        find.byKey(const ValueKey('work-resource-recommendations-tab')),
        findsNothing,
      );
      expect(recommendationCreates, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('visible resource images resolve before the rest of the page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tree = ValueNotifier<List<dynamic>>([
      for (var index = 0; index < 41; index++)
        {'type': 'image', 'title': 'image$index.png', 'hash': 'image$index'},
    ]);
    final scroll = ScrollController();
    addTearDown(tree.dispose);
    addTearDown(scroll.dispose);
    final calls = <String>[];
    final gates = <String, Completer<PreviewFileItem?>>{};
    Future<PreviewFileItem?> resolve(dynamic file) {
      final hash = file['hash'] as String;
      calls.add(hash);
      final gate = Completer<PreviewFileItem?>();
      gates[hash] = gate;
      return gate.future;
    }

    await _pumpResources(tester, tree, resolveImage: resolve);
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, isNotEmpty);
    expect(calls.length, lessThan(20));
    expect(calls.toSet().length, calls.length);
    final visibleHashes = <String>{};
    for (var index = 0; index < 20; index++) {
      final card = find.ancestor(
        of: find.text('image$index.png'),
        matching: find.byType(Card),
      );
      if (card.evaluate().isEmpty) continue;
      final rect = tester.getRect(card);
      if (rect.bottom > 0 && rect.top < 500) {
        visibleHashes.add('image$index');
      }
    }
    expect(visibleHashes, isNotEmpty);
    expect(calls.every(visibleHashes.contains), isTrue);
    final loadingSpinner = _loadingOverlaySpinner();
    expect(loadingSpinner, findsOneWidget);
    expect(
      tester
          .getRect(loadingSpinner)
          .overlaps(Offset.zero & const Size(390, 500)),
      isTrue,
    );
    final pendingVisibleCalls = List<String>.of(calls);
    await tester.pump(const Duration(milliseconds: 100));
    expect(calls, pendingVisibleCalls);

    gates[calls.first]!.complete(null);
    await tester.pump();
    await tester.pump();
    final firstFailedCard = find.ancestor(
      of: find.text('${calls.first}.png'),
      matching: find.byType(Card),
    );
    final firstFailedCardVisibility = find
        .ancestor(of: firstFailedCard, matching: find.byType(Visibility))
        .first;
    expect(
      tester.widget<Visibility>(firstFailedCardVisibility).visible,
      isFalse,
    );

    for (var frame = 0; frame < 80 && calls.length < 20; frame++) {
      for (final hash in calls) {
        final gate = gates[hash]!;
        if (!gate.isCompleted) gate.complete(null);
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (final hash in calls) {
      final gate = gates[hash]!;
      if (!gate.isCompleted) gate.complete(null);
    }
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(calls, hasLength(20));
    expect(calls.toSet(), {
      for (var index = 0; index < 20; index++) 'image$index',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending first-screen spinner stays visible during fast scroll', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tree = ValueNotifier<List<dynamic>>([
      for (var index = 0; index < 20; index++)
        {'type': 'image', 'title': 'image$index.png', 'hash': 'image$index'},
    ]);
    final scroll = ScrollController();
    addTearDown(tree.dispose);
    addTearDown(scroll.dispose);
    final pending = <String, Completer<PreviewFileItem?>>{};
    await _pumpResources(
      tester,
      tree,
      controller: scroll,
      resolveImage: (file) {
        final hash = file['hash'] as String;
        return (pending[hash] ??= Completer<PreviewFileItem?>()).future;
      },
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    });

    final firstScreenSpinner = _loadingOverlaySpinner();
    expect(firstScreenSpinner, findsOneWidget);
    expect(
      tester
          .getRect(firstScreenSpinner)
          .overlaps(Offset.zero & const Size(390, 500)),
      isTrue,
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();

    final spinner = _loadingOverlaySpinner();
    expect(spinner, findsOneWidget);
    expect(
      tester.getRect(spinner).overlaps(Offset.zero & const Size(390, 500)),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving the resource image tab drops queued preloads', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tree = ValueNotifier<List<dynamic>>([
      for (var index = 0; index < 41; index++)
        {'type': 'image', 'title': 'image$index.png', 'hash': 'image$index'},
    ]);
    addTearDown(tree.dispose);
    final calls = <String>[];
    final gates = <String, Completer<PreviewFileItem?>>{};
    Future<PreviewFileItem?> resolve(dynamic file) {
      final hash = file['hash'] as String;
      calls.add(hash);
      final gate = Completer<PreviewFileItem?>();
      gates[hash] = gate;
      return gate.future;
    }

    await _pumpResources(tester, tree, resolveImage: resolve);
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final started = calls.toSet();
    expect(started, isNotEmpty);
    expect(started.length, lessThan(20));

    await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    for (final hash in started) {
      gates[hash]!.complete(null);
    }
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(calls.toSet(), started);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching image pages resets the first-screen gate', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tree = ValueNotifier<List<dynamic>>([
      for (var index = 0; index < 41; index++)
        {'type': 'image', 'title': 'image$index.png', 'hash': 'image$index'},
    ]);
    final scroll = ScrollController();
    addTearDown(tree.dispose);
    addTearDown(scroll.dispose);
    final pending = <String, Completer<PreviewFileItem?>>{};
    final calls = <String>[];
    Future<PreviewFileItem?> resolve(dynamic file) {
      final hash = file['hash'] as String;
      calls.add(hash);
      if (int.parse(hash.substring(5)) < 20) return Future.value(null);
      return (pending[hash] ??= Completer<PreviewFileItem?>()).future;
    }

    await _pumpResources(
      tester,
      tree,
      controller: scroll,
      resolveImage: resolve,
    );
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pumpAndSettle();
    expect(_loadingOverlaySpinner(), findsNothing);

    final scrollable = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Next'),
      180,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pump(const Duration(milliseconds: 300));
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final pageTwoSpinner = _loadingOverlaySpinner();
    expect(pageTwoSpinner, findsOneWidget);
    expect(
      tester
          .getRect(pageTwoSpinner)
          .overlaps(Offset.zero & const Size(390, 500)),
      isTrue,
    );
    final firstPageTwoCard = find.ancestor(
      of: find.text('image20.png'),
      matching: find.byType(Card),
    );
    expect(
      tester
          .widget<Visibility>(
            find
                .ancestor(
                  of: firstPageTwoCard,
                  matching: find.byType(Visibility),
                )
                .first,
          )
          .visible,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('background resource images reuse the displayed decode size', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = Directory.systemTemp.createTempSync('resource-prewarm-');
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      directory.deleteSync(recursive: true);
    });
    final files = <dynamic>[
      for (var index = 0; index < 20; index++)
        {'type': 'image', 'title': 'warm$index.png', 'hash': 'warm$index'},
    ];
    final imageFiles = <String, File>{};
    for (final file in files) {
      final hash = file['hash'] as String;
      imageFiles[hash] = File('${directory.path}/$hash.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 60, height: 30)));
    }
    final tree = ValueNotifier(files);
    final scroll = ScrollController();
    addTearDown(tree.dispose);
    addTearDown(scroll.dispose);
    final calls = <String>[];
    await _pumpResources(
      tester,
      tree,
      controller: scroll,
      resolveImage: (file) async {
        final hash = file['hash'] as String;
        calls.add(hash);
        return PreviewFileItem(
          url: LocalFileUrl.fromPath(imageFiles[hash]!.path),
          title: file['title'] as String,
          hash: hash,
        );
      },
    );
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final firstImage = find.descendant(
      of: find.ancestor(
        of: find.text('warm0.png'),
        matching: find.byType(Card),
      ),
      matching: find.byType(Image),
    );
    for (var frame = 0; frame < 10 && firstImage.evaluate().isEmpty; frame++) {
      await tester.pump();
    }
    await _pumpUntilImageLoaded(tester, firstImage);
    final displayedProvider =
        tester.widget<Image>(firstImage).image as ResizeImage;
    final preloadedProvider = CachedImageWidget.imageProvider(
      imageUrl: LocalFileUrl.fromPath(imageFiles['warm19']!.path),
      hash: 'warm19',
      cacheWidth: displayedProvider.width,
    );
    final cacheKey = await preloadedProvider.obtainKey(
      ImageConfiguration.empty,
    );
    for (
      var frame = 0;
      frame < 100 &&
          !PaintingBinding.instance.imageCache.statusForKey(cacheKey).keepAlive;
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      calls,
      hasLength(20),
      reason:
          'Visible local images must decode before background prefetch begins.',
    );
    expect(calls.toSet(), hasLength(20));
    expect(
      PaintingBinding.instance.imageCache.statusForKey(cacheKey).keepAlive,
      isTrue,
    );
    for (final card in find.byType(Card).evaluate()) {
      final cardFinder = find.byWidget(card.widget);
      final rect = tester.getRect(cardFinder);
      if (rect.bottom <= 0 || rect.top >= 500) continue;
      expect(
        tester
            .widget<Visibility>(
              find
                  .ancestor(of: cardFinder, matching: find.byType(Visibility))
                  .first,
            )
            .visible,
        isTrue,
        reason: 'Visible cards must update after wide images shorten the grid.',
      );
    }
    expect(find.byKey(ObjectKey(files.last)), findsNothing);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    final returnedImage = find.descendant(
      of: find.ancestor(
        of: find.text('warm19.png'),
        matching: find.byType(Card),
      ),
      matching: find.byType(RawImage),
    );
    expect(returnedImage, findsOneWidget);
    final neverDisplayedCard = find.ancestor(
      of: find.text('warm19.png'),
      matching: find.byType(Card),
    );
    final neverDisplayedVisibility = find
        .ancestor(of: neverDisplayedCard, matching: find.byType(Visibility))
        .first;
    expect(tester.widget<Visibility>(neverDisplayedVisibility).visible, isTrue);
    expect(tester.widget<RawImage>(returnedImage).image, isNotNull);
    expect(calls, hasLength(20));

    scroll.jumpTo(0);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-resource-audio-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pumpAndSettle();
    expect(_loadingOverlaySpinner(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a slow resource picture does not block background progress', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final files = <dynamic>[
      for (var index = 0; index < 20; index++)
        {
          'type': 'image',
          'title': 'pending$index.png',
          'hash': 'pending$index',
        },
    ];
    final tree = ValueNotifier(files);
    final gates = <int, Completer<PreviewFileItem?>>{};
    addTearDown(tree.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      for (final gate in gates.values) {
        if (!gate.isCompleted) gate.complete();
      }
      await tester.pump();
    });
    await _pumpResources(
      tester,
      tree,
      resolveImage: (file) {
        final index = files.indexOf(file);
        return (gates[index] = Completer<PreviewFileItem?>()).future;
      },
    );
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final visible = <int>{};
    for (var index = 0; index < files.length; index++) {
      final card = find.ancestor(
        of: find.text('pending$index.png'),
        matching: find.byType(Card),
      );
      if (card.evaluate().isNotEmpty &&
          tester.getRect(card).overlaps(const Rect.fromLTWH(0, 0, 390, 500))) {
        visible.add(index);
      }
    }
    expect(visible, isNotEmpty);
    for (var frame = 0; frame < 30; frame++) {
      for (final index in visible) {
        final gate = gates[index];
        if (gate != null && !gate.isCompleted) gate.complete();
      }
      await tester.pump(const Duration(milliseconds: 16));
      if (_loadingOverlaySpinner().evaluate().isEmpty) break;
    }
    expect(_loadingOverlaySpinner(), findsNothing);
    final background = gates.keys
        .where((index) => !visible.contains(index))
        .toList();
    expect(
      background,
      hasLength(2),
      reason: 'One slow target must leave another background picture loading.',
    );
    gates[background.last]!.complete();
    await tester.pump();
    await tester.pump();
    expect(gates.length, visible.length + 3);
    expect(gates[background.first]!.isCompleted, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resource scrolling keeps upcoming frames under cache pressure', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 1500);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final cache = PaintingBinding.instance.imageCache;
    final oldLimit = cache.maximumSizeBytes;
    cache.maximumSizeBytes = 12 * 1024 * 1024;
    final directory = Directory.systemTemp.createTempSync('resource-scroll-');
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      cache.clear();
      cache.clearLiveImages();
      cache.maximumSizeBytes = oldLimit;
      directory.deleteSync(recursive: true);
    });
    final bytes = img.encodePng(img.Image(width: 600, height: 900));
    final files = <dynamic>[
      for (var index = 0; index < 20; index++)
        {'type': 'image', 'title': 'scroll$index.png', 'hash': 'scroll$index'},
    ];
    final imageFiles = <String, File>{
      for (final file in files)
        file['hash'] as String: File('${directory.path}/${file['hash']}.png')
          ..writeAsBytesSync(bytes),
    };
    final tree = ValueNotifier(files);
    final scroll = ScrollController();
    addTearDown(tree.dispose);
    addTearDown(scroll.dispose);
    final calls = <String>[];
    await _pumpResources(
      tester,
      tree,
      controller: scroll,
      resolveImage: (file) async {
        final hash = file['hash'] as String;
        calls.add(hash);
        return PreviewFileItem(
          url: LocalFileUrl.fromPath(imageFiles[hash]!.path),
          title: file['title'] as String,
          hash: hash,
        );
      },
    );
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final firstImage = find.descendant(
      of: find.ancestor(
        of: find.text('scroll0.png'),
        matching: find.byType(Card),
      ),
      matching: find.byType(Image),
    );
    for (var frame = 0; frame < 10 && firstImage.evaluate().isEmpty; frame++) {
      await tester.pump();
    }
    await _pumpUntilImageLoaded(tester, firstImage);
    final width =
        (tester.widget<Image>(firstImage).image as ResizeImage).width!;
    expect(width, greaterThan(500));
    final lastKey = await CachedImageWidget.imageProvider(
      imageUrl: LocalFileUrl.fromPath(imageFiles['scroll19']!.path),
      hash: 'scroll19',
      cacheWidth: width,
    ).obtainKey(ImageConfiguration.empty);
    for (
      var frame = 0;
      frame < 180 &&
          (!cache.statusForKey(lastKey).keepAlive ||
              cache.pendingImageCount > 0);
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(calls, hasLength(20));
    expect(cache.statusForKey(lastKey).keepAlive, isTrue);
    expect(find.byKey(ObjectKey(files[6])), findsNothing);
    final upcomingKey = await CachedImageWidget.imageProvider(
      imageUrl: LocalFileUrl.fromPath(imageFiles['scroll6']!.path),
      hash: 'scroll6',
      cacheWidth: width,
    ).obtainKey(ImageConfiguration.empty);
    expect(
      cache.statusForKey(upcomingKey).keepAlive,
      isFalse,
      reason:
          'The regression must exercise a decoded frame evicted by background warming.',
    );
    expect(cache.statusForKey(upcomingKey).live, isTrue);

    scroll.jumpTo(600);
    await tester.pump();
    final nextCard = find.ancestor(
      of: find.text('scroll6.png'),
      matching: find.byType(Card),
    );
    expect(
      tester.getRect(nextCard).overlaps(const Rect.fromLTWH(0, 0, 390, 500)),
      isTrue,
    );
    final nextFrame = find.descendant(
      of: nextCard,
      matching: find.byType(RawImage),
    );
    expect(nextFrame, findsOneWidget);
    expect(
      tester.widget<RawImage>(nextFrame).image,
      isNotNull,
      reason:
          'Nearby prewarmed pictures must remain ready for downward scrolling.',
    );
    expect(calls, hasLength(20));
    scroll.jumpTo(0);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-resource-audio-tab')));
    await tester.pumpAndSettle();
    expect(
      cache.statusForKey(upcomingKey).live,
      isFalse,
      reason: 'Leaving the image tab must release the upcoming frame.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote resource prefetch updates never-mounted cards', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = Directory.systemTemp.createTempSync('remote-resource-');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (_) async => directory.path,
    );
    final previousCache = CachedNetworkImageProvider.defaultCacheManager;
    CacheService.installImageCacheManager();
    final id = DateTime.now().microsecondsSinceEpoch;
    final files = <dynamic>[
      for (var index = 0; index < 20; index++)
        {
          'type': 'image',
          'title': 'remote$index.png',
          'hash': 'remote-$id-$index',
        },
    ];
    final urls = {
      for (var index = 0; index < 20; index++)
        'remote-$id-$index': 'https://assets.invalid/$id/$index.png',
    };
    final imageBytes = img.encodePng(img.Image(width: 60, height: 30));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      CachedNetworkImageProvider.defaultCacheManager = previousCache;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
        null,
      );
      directory.deleteSync(recursive: true);
    });
    await tester.runAsync(() async {
      for (final entry in urls.entries) {
        final cacheKey = CacheService.imageCacheKey(
          imageUrl: entry.value,
          hash: entry.key,
        )!;
        await CacheService.imageCacheManager.putFile(
          entry.value,
          imageBytes,
          key: cacheKey,
          fileExtension: 'png',
        );
        expect(
          await CacheService.imageCacheManager.getFileFromCache(cacheKey),
          isNotNull,
        );
      }
    });

    final tree = ValueNotifier<List<dynamic>>(files);
    final scroll = ScrollController();
    addTearDown(tree.dispose);
    addTearDown(scroll.dispose);
    final calls = <String>[];
    await _pumpResources(
      tester,
      tree,
      controller: scroll,
      resolveImage: (file) async {
        final hash = file['hash'] as String;
        calls.add(hash);
        return PreviewFileItem(
          url: urls[hash]!,
          title: file['title'] as String,
          hash: hash,
        );
      },
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    });
    final firstCard = find
        .ancestor(of: find.text('remote0.png'), matching: find.byType(Card))
        .first;
    final cacheWidth =
        (tester.getSize(firstCard).width *
                MediaQuery.devicePixelRatioOf(tester.element(firstCard)))
            .ceil();
    final lastHash = files.last['hash'] as String;
    final preloadedProvider = CachedImageWidget.imageProvider(
      imageUrl: urls[lastHash]!,
      hash: lastHash,
      cacheWidth: cacheWidth,
    );
    final cacheKey = await preloadedProvider.obtainKey(
      ImageConfiguration.empty,
    );
    for (
      var frame = 0;
      frame < 300 &&
          (calls.length < 20 ||
              !PaintingBinding.instance.imageCache
                  .statusForKey(cacheKey)
                  .keepAlive);
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    final imageException = tester.takeException();
    final rawImages = tester.widgetList<RawImage>(find.byType(RawImage));
    expect(
      calls,
      hasLength(20),
      reason:
          'Remote visible images must decode before background prefetch begins; '
          'calls=${calls.length}, warm19.keepAlive='
          '${PaintingBinding.instance.imageCache.statusForKey(cacheKey).keepAlive}, '
          'decodedFrames=${rawImages.where((image) => image.image != null).length}, '
          'retryCards=${find.byIcon(Icons.broken_image_outlined).evaluate().length}, '
          'exception=$imageException',
    );
    expect(imageException, isNull);
    expect(
      PaintingBinding.instance.imageCache.statusForKey(cacheKey).keepAlive,
      isTrue,
    );
    expect(find.byKey(ObjectKey(files.last)), findsNothing);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    final returnedImage = find.descendant(
      of: find.ancestor(
        of: find.text('remote19.png'),
        matching: find.byType(Card),
      ),
      matching: find.byType(RawImage),
    );
    expect(returnedImage, findsOneWidget);
    final returnedCard = find.ancestor(
      of: find.text('remote19.png'),
      matching: find.byType(Card),
    );
    expect(
      tester
          .widget<Visibility>(
            find
                .ancestor(of: returnedCard, matching: find.byType(Visibility))
                .first,
          )
          .visible,
      isTrue,
    );
    expect(tester.widget<RawImage>(returnedImage).image, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('image scrolling stays separate from the recommendation tab', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tree = ValueNotifier<List<dynamic>>([
      for (var index = 0; index < 41; index++)
        {'type': 'image', 'title': 'image$index.png', 'hash': 'image$index'},
    ]);
    final scroll = ScrollController();
    addTearDown(tree.dispose);
    addTearDown(scroll.dispose);
    await _pumpResources(
      tester,
      tree,
      controller: scroll,
      recommendationCount: 100,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pumpAndSettle();
    for (var step = 0; step < 25; step++) {
      final before = scroll.offset;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -240));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThanOrEqualTo(before));
    }
    expect(scroll.offset, greaterThan(1000));
    expect(find.textContaining('recommendation '), findsNothing);
    expect(
      tester
          .widget<TabBar>(find.byType(TabBar, skipOffstage: false))
          .controller!
          .index,
      2,
    );
    await tester.binding.setSurfaceSize(const Size(900, 500));
    await tester.pumpAndSettle();
    final beforeRotationScroll = scroll.offset;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThanOrEqualTo(beforeRotationScroll));
    expect(find.textContaining('recommendation '), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('work-resource-recommendations-tab')),
    );
    await tester.tap(
      find.byKey(const ValueKey('work-resource-recommendations-tab')),
    );
    await tester.pumpAndSettle();
    expect(find.text('recommendation 0'), findsOneWidget);
    expect(
      tester
          .widget<TabBar>(find.byType(TabBar, skipOffstage: false))
          .controller!
          .index,
      3,
    );
  });

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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
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
    await tester.binding.setSurfaceSize(const Size(390, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = Directory.systemTemp.createTempSync(
      'work-resource-images-',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      directory.deleteSync(recursive: true);
    });
    final imageFiles = <String, File>{};
    final files = List<dynamic>.generate(20, (index) {
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
    await tester.pump(const Duration(milliseconds: 300));

    Finder firstCard() =>
        find.ancestor(of: find.text('image0.png'), matching: find.byType(Card));

    final initialCard = firstCard();
    final initialImage = find.descendant(
      of: initialCard,
      matching: find.byType(Image),
    );
    for (
      var frame = 0;
      frame < 10 && initialImage.evaluate().isEmpty;
      frame++
    ) {
      await tester.pump();
    }
    expect(initialImage, findsOneWidget);
    await _pumpUntilImageLoaded(tester, initialImage);
    await tester.pump(const Duration(milliseconds: 200));
    final initialCardHeight = tester.getRect(initialCard).height;
    expect(
      tester.getRect(initialImage).width / tester.getRect(initialImage).height,
      closeTo(0.5, 0.01),
    );

    await tester.scrollUntilVisible(
      find.text('image19.png'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(firstCard().hitTestable(), findsNothing);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    controller.jumpTo(0);
    await tester.pump();

    final returnedCard = firstCard();
    expect(returnedCard, findsOneWidget);
    expect(tester.getRect(returnedCard).height, closeTo(initialCardHeight, 1));
    expect(tester.takeException(), isNull);
    final returnedImage = find.descendant(
      of: returnedCard,
      matching: find.byType(Image),
    );
    for (
      var frame = 0;
      frame < 100 && returnedImage.evaluate().isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(returnedImage, findsOneWidget);
    await _pumpUntilImageLoaded(tester, returnedImage);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('new image cards stay hidden until their ratio is decoded', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = Directory.systemTemp.createTempSync(
      'work-resource-first-image-',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      directory.deleteSync(recursive: true);
    });
    final file = File('${directory.path}/portrait.png')
      ..writeAsBytesSync(img.encodePng(img.Image(width: 80, height: 160)));
    final tree = ValueNotifier<List<dynamic>>([
      {'type': 'image', 'title': 'portrait.png', 'hash': 'portrait'},
    ]);
    addTearDown(tree.dispose);
    final target = Completer<PreviewFileItem?>();
    await _pumpResources(tester, tree, resolveImage: (_) => target.future);
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final card = find.ancestor(
      of: find.text('portrait.png'),
      matching: find.byType(Card),
    );
    expect(card, findsOneWidget);
    final visibility = find
        .ancestor(of: card, matching: find.byType(Visibility))
        .first;
    expect(tester.widget<Visibility>(visibility).visible, isFalse);
    expect(tester.widget<Visibility>(visibility).maintainSize, isTrue);
    expect(tester.widget<Visibility>(visibility).maintainAnimation, isTrue);
    expect(tester.widget<Visibility>(visibility).maintainState, isTrue);

    target.complete(
      PreviewFileItem(
        url: LocalFileUrl.fromPath(file.path),
        title: 'portrait.png',
        hash: 'portrait',
      ),
    );
    await tester.pump();
    final image = find.descendant(of: card, matching: find.byType(Image));
    for (var frame = 0; frame < 10 && image.evaluate().isEmpty; frame++) {
      await tester.pump();
    }
    expect(image, findsOneWidget);
    expect(tester.widget<Visibility>(visibility).visible, isFalse);
    expect(
      tester
          .widget<RawImage>(
            find.descendant(of: image, matching: find.byType(RawImage)),
          )
          .image,
      isNull,
    );

    await _pumpUntilImageLoaded(tester, image);
    await tester.pump();
    expect(tester.widget<Visibility>(visibility).visible, isTrue);
    expect(
      tester.getRect(image).width / tester.getRect(image).height,
      closeTo(0.5, 0.01),
    );
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
      final resourceTab = tester.getRect(
        find
            .descendant(of: find.byType(TabBar), matching: find.byType(InkWell))
            .first,
      );
      expect(resourceTab.left, 0);
      expect(resourceTab.width, closeTo(width / 2, 1));
      expect(find.text('Resources'), findsOneWidget);
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
      expect(find.byType(PaginationBar), findsNothing);
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
      expect(tabs.controller!.index, 1);
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

  testWidgets('images paginate by twenty and report only the selected page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final files = List<dynamic>.generate(
      41,
      (index) => {
        'type': 'image',
        'title': 'image$index.png',
        'hash': 'image$index',
      },
    );
    final tree = ValueNotifier<List<dynamic>>(files);
    addTearDown(tree.dispose);
    final reports = <List<String>>[];
    final resolved = <String>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _pumpResources(
      tester,
      tree,
      controller: controller,
      onVisibleNamesChanged: reports.add,
      resolveImage: (file) async {
        resolved.add(file['hash'] as String);
        return null;
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pumpAndSettle();

    expect(reports.last, [for (var i = 0; i < 20; i++) 'image$i.png']);
    expect(resolved, isNotEmpty);
    expect(
      resolved.toSet().every((hash) => int.parse(hash.substring(5)) < 20),
      isTrue,
    );
    final scrollable = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Next'),
      180,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('Page 1 / 3'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(reports.last, [for (var i = 20; i < 40; i++) 'image$i.png']);
    expect(controller.offset, closeTo(0, 1));
    expect(resolved, contains('image20'));

    await tester.tap(find.byKey(const ValueKey('work-resource-audio-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pumpAndSettle();
    expect(reports.last, [for (var i = 20; i < 40; i++) 'image$i.png']);
    await tester.scrollUntilVisible(
      find.text('Jump'),
      180,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('Page 2 / 3'), findsOneWidget);
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Jump'));
    await tester.pumpAndSettle();
    expect(reports.last, ['image40.png']);
    expect(find.byKey(ObjectKey(files[40])), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Previous'),
      180,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Previous'));
    await tester.pumpAndSettle();
    expect(reports.last, [for (var i = 20; i < 40; i++) 'image$i.png']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resource tabs swipe, retarget, and honor reduced motion', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tree = ValueNotifier(_files(images: true));
    addTearDown(tree.dispose);
    final reports = <List<String>>[];
    await _pumpResources(tester, tree, onVisibleNamesChanged: reports.add);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pump();
    final tabs = tester.widget<TabBar>(find.byType(TabBar)).controller!;
    expect(tabs.animation!.value, closeTo(1, 0.01));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tabs.animation!.value, greaterThan(1));
    expect(tabs.animation!.value, lessThan(2));
    await tester.pumpAndSettle();
    expect(reports.last, ['one.png', 'two.png']);
    expect(tabs.index, 2);

    await tester.tap(find.byKey(const ValueKey('work-resource-audio-tab')));
    await tester.pumpAndSettle();
    await tester.drag(find.text('track01.wav'), const Offset(-280, 0));
    await tester.pumpAndSettle();
    expect(reports.last, ['one.png', 'two.png']);
    expect(tabs.index, 2);

    await tester.tap(find.byKey(const ValueKey('work-resource-audio-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
    await tester.pumpAndSettle();
    expect(find.text('whole resource tree'), findsOneWidget);
    expect(tabs.index, 0);

    await tester.ensureVisible(
      find.byKey(const ValueKey('work-resource-images-tab')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    tree.value = _files();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('work-resource-images-tab')),
      findsNothing,
    );
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
    expect(tester.takeException(), isNull);

    tree.value = _files(images: true);
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    await _pumpResources(tester, tree, disableAnimations: true);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
    await tester.pump();
    expect(find.text('whole resource tree'), findsOneWidget);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
    expect(tester.takeException(), isNull);
  });
}
