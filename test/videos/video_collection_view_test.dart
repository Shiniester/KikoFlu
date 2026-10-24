import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_collection_view.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

const _video = VideoItem(
  id: 'sample',
  title: 'Sample video with a title that wraps across two lines',
  pageUrl: 'https://missav.ai/cn/sample',
  durationSeconds: 3723,
  releaseDate: '2024-03-02',
  hasSubtitles: true,
  isUncensored: true,
  actors: [
    VideoLink(
      label: 'Sample actor',
      url: 'https://missav.ai/cn/actresses/sample',
      kind: VideoLinkKind.actor,
    ),
  ],
  tags: [
    VideoLink(
      label: 'Drama',
      url: 'https://missav.ai/cn/genres/drama',
      kind: VideoLinkKind.category,
    ),
    VideoLink(
      label: 'A long tag that must fit within the card',
      url: 'https://missav.ai/cn/genres/long',
      kind: VideoLinkKind.category,
    ),
  ],
);

VideoItem _richVideo() => VideoItem(
  id: 'rich',
  title: 'A video with several actresses and a full set of tags',
  pageUrl: 'https://missav.ai/cn/rich',
  durationSeconds: 3723,
  releaseDate: '2024-03-02',
  hasSubtitles: true,
  isUncensored: true,
  actors: [
    for (final name in ['Actress A', 'Actress B', 'Actress C', 'Actress D'])
      VideoLink(
        label: name,
        url: 'https://missav.ai/cn/actresses/$name',
        kind: VideoLinkKind.actor,
      ),
  ],
  tags: [
    for (var index = 1; index <= 8; index++)
      VideoLink(
        label: 'Tag $index',
        url: 'https://missav.ai/cn/genres/tag-$index',
        kind: VideoLinkKind.category,
      ),
  ],
);

void main() {
  testWidgets(
    'cover badges occupy their requested corners and metadata opens its catalog',
    (tester) async {
      var openedVideo = false;
      VideoLink? openedLink;
      await tester.pumpWidget(
        _app(
          Center(
            child: SizedBox(
              width: 260,
              child: VideoCard(
                video: _video,
                layoutType: LayoutType.bigGrid,
                onTap: () => openedVideo = true,
                onOpenLink: (link) => openedLink = link,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final cover = tester.getRect(
        find.byKey(const ValueKey('video-cover-sample')),
      );
      expect(cover.width / cover.height, closeTo(4 / 3, .001));
      final duration = tester.getRect(
        find.byKey(const ValueKey('video-duration-sample')),
      );
      final release = tester.getRect(
        find.byKey(const ValueKey('video-release-sample')),
      );
      expect(duration.center.dx, greaterThan(cover.center.dx));
      expect(duration.center.dy, lessThan(cover.center.dy));
      expect(release.center.dx, greaterThan(cover.center.dx));
      expect(release.center.dy, greaterThan(cover.center.dy));
      for (final icon in [Icons.closed_caption, Icons.no_encryption_outlined]) {
        final bounds = tester.getRect(find.byIcon(icon));
        expect(bounds.center.dx, lessThan(cover.center.dx));
        expect(bounds.center.dy, greaterThan(cover.center.dy));
      }
      expect(
        tester.getRect(find.text('Sample actor')).top,
        greaterThan(cover.bottom),
      );
      await tester.tap(find.text('Drama'));
      expect(openedLink?.url, _video.tags.first.url);
      expect(openedVideo, isFalse);
      await tester.tap(find.text(_video.title));
      expect(openedVideo, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing source metadata leaves no badges or placeholder labels',
    (tester) async {
      await tester.pumpWidget(
        _app(
          const Center(
            child: SizedBox(
              width: 180,
              child: VideoCard(
                video: VideoItem(
                  id: 'empty',
                  title: 'Title only',
                  pageUrl: 'https://missav.ai/cn/empty',
                ),
                layoutType: LayoutType.smallGrid,
                onTap: null,
              ),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.closed_caption), findsNothing);
      expect(find.byIcon(Icons.no_encryption_outlined), findsNothing);
      expect(find.byType(Tooltip), findsNothing);
      expect(find.text('Title only'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dense metadata stays compact and exposes the remaining entries',
    (tester) async {
      var opened = false;
      final video = _richVideo();
      await tester.pumpWidget(
        _app(
          Center(
            child: SizedBox(
              width: 180,
              child: VideoCard(
                video: video,
                layoutType: LayoutType.smallGrid,
                onTap: () => opened = true,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Actress A'), findsOneWidget);
      expect(find.text('Actress C'), findsNothing);
      expect(find.text('Tag 3'), findsOneWidget);
      expect(find.text('Tag 4'), findsNothing);
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('+5'), findsOneWidget);
      expect(find.byTooltip('Tag 4、Tag 5、Tag 6、Tag 7、Tag 8'), findsOneWidget);
      await tester.tap(find.text('+5'));
      expect(opened, isTrue);
      expect(video.tags, hasLength(8));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        _app(
          Center(
            child: SizedBox(
              width: 320,
              child: VideoCard(
                video: _video,
                layoutType: LayoutType.list,
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      final cover = tester.getRect(find.byType(VideoCover));
      final actress = tester.getRect(find.text('Sample actor'));
      expect(actress.left, greaterThan(cover.right));
      expect(actress.top, lessThan(cover.bottom));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all layouts fit narrow and wide windows with larger text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    for (final width in [320.0, 840.0, 1280.0]) {
      tester.view.physicalSize = Size(width, 900);
      for (final layout in LayoutType.values) {
        await tester.pumpWidget(
          _app(
            VideoCollectionView<VideoItem>(
              items: [_video, _richVideo()],
              layoutType: layout,
              itemId: (video) => video.id,
              itemBuilder: (_, video, _) =>
                  VideoCard(video: video, layoutType: layout, onTap: () {}),
              controller: controller,
              pageStorageKey: const PageStorageKey('card-layout'),
              emptyBuilder: (_) => const SizedBox.shrink(),
            ),
            textScale: 1.3,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$width $layout');
        final cover = tester.getSize(find.byType(VideoCover).first);
        expect(cover.width / cover.height, closeTo(4 / 3, .001));
        if (layout == LayoutType.list) expect(cover, const Size(80, 60));
      }
    }
  });

  testWidgets('writes the video card layout preview', (tester) async {
    final fonts =
        '${File(Platform.resolvedExecutable).parent.parent.parent.path}/material_fonts';
    for (final font in [
      ('Roboto', 'roboto-regular.ttf'),
      ('MaterialIcons', 'materialicons-regular.otf'),
    ]) {
      await (FontLoader(font.$1)..addFont(
            Future.value(
              ByteData.sublistView(
                Directory(fonts)
                    .listSync()
                    .whereType<File>()
                    .singleWhere(
                      (file) =>
                          file.uri.pathSegments.last.toLowerCase() == font.$2,
                    )
                    .readAsBytesSync(),
              ),
            ),
          ))
          .load();
    }
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('video-card-preview'),
        child: _app(
          ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var index = 0; index < 2; index++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: VideoCard(
                          video: index == 0 ? _video : _richVideo(),
                          layoutType: LayoutType.bigGrid,
                          onTap: () {},
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              VideoCard(
                video: _richVideo(),
                layoutType: LayoutType.list,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('video-card-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await Directory('build').create(recursive: true);
      await File('build/video-card-layout-preview.png').writeAsBytes(
        data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    });
    expect(tester.takeException(), isNull);
  });
}

Widget _app(Widget child, {double textScale = 1}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  locale: const Locale('en'),
  supportedLocales: S.supportedLocales,
  localizationsDelegates: S.localizationsDelegates,
  theme: ThemeData(useMaterial3: true, fontFamily: 'Roboto'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(body: child),
);
