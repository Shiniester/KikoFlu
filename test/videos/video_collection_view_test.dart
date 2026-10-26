import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_collection_view.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:kikoeru_flutter/src/videos/video_card_display_provider.dart';

const _video = VideoItem(
  id: 'sample',
  title: 'ABC-123 Sample video with a title that wraps across two lines',
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
  title:
      'FC2-PPV-1234567 A video with several actresses and a full set of tags',
  pageUrl: 'https://missav.ai/cn/rich',
  durationSeconds: 3723,
  releaseDate: '2024-03-02',
  hasSubtitles: true,
  isUncensored: true,
  makers: ['Studio A'],
  labels: ['Label A'],
  series: ['Series A'],
  directors: ['Director A'],
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
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('catalog numbers omit source variants and survive saved video data', () {
    for (final (id, title, number) in [
      ('abc-123', 'Sample video', 'ABC-123'),
      ('abc-123-uncensored-leak', 'Sample video', 'ABC-123'),
      ('abc-123-chinese-subtitle', 'Sample video', 'ABC-123'),
      ('fc2-ppv-1234567-uncensored', 'Sample video', 'FC2-PPV-1234567'),
      ('010123_001-uncensored', 'Sample video', '010123_001'),
      ('n1234', 'Sample video', 'N1234'),
      ('source-entry', 'abc-123 Sample video', 'ABC-123'),
      ('abc-123', 'FC2-PPV-1234567 Sample video', 'FC2-PPV-1234567'),
      ('source-entry', 'Sample video', null),
      ('', '', null),
    ]) {
      final video = VideoItem(id: id, title: title, pageUrl: '');
      expect(video.catalogNumber, number, reason: id);
      expect(VideoItem.fromJson(video.toJson()).catalogNumber, number);
    }
  });

  testWidgets('catalog number stays at the cover top left in every layout', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      for (final field in VideoCardField.values)
        'video_card_display_${field.name}': false,
    });
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final layout in LayoutType.values) {
      await tester.pumpWidget(
        _app(
          Center(
            child: SizedBox(
              width: layout == LayoutType.list ? 320 : 180,
              child: VideoCard(video: _video, layoutType: layout, onTap: null),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final cover = tester.getRect(
        find.byKey(const ValueKey('video-cover-sample')),
      );
      final number = tester.getRect(
        find.byKey(const ValueKey('video-number-sample')),
      );
      expect(find.text('ABC-123'), findsOneWidget);
      expect(number.left, greaterThan(cover.left));
      expect(number.top, greaterThan(cover.top));
      expect(number.center.dy, lessThan(cover.center.dy));
      expect(cover.contains(number.bottomRight), isTrue);
      final text = tester.widget<Text>(find.text('ABC-123'));
      expect(text.style?.color, Colors.white);
      expect(text.style?.fontWeight, FontWeight.bold);
      expect(tester.takeException(), isNull, reason: '$layout');
    }
  });

  testWidgets('video cover decode stays within its physical display width', (
    tester,
  ) async {
    const displayWidth = 80.0;
    const devicePixelRatio = 3.0;
    const sourceWidth = 1600;
    const sourceHeight = 1200;
    final sourceBytes = Uint8List.fromList(
      img.encodePng(img.Image(width: sourceWidth, height: sourceHeight)),
    );
    final previousHttpClientProvider = debugNetworkImageHttpClientProvider;
    debugNetworkImageHttpClientProvider = () =>
        _VideoCoverHttpClient(sourceBytes);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });

    try {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _app(
          const Center(
            child: SizedBox(
              width: displayWidth,
              height: displayWidth * 3 / 4,
              child: VideoCover(
                video: VideoItem(
                  id: 'decode-size',
                  title: 'Decode size',
                  pageUrl: 'https://missav.ai/cn/decode-size',
                  cover: 'https://missav.ai/images/decode-size.png',
                ),
              ),
            ),
          ),
        ),
      );

      final cover = find.byKey(const ValueKey('video-cover-decode-size'));
      expect(
        tester.getSize(cover),
        const Size(displayWidth, displayWidth * 3 / 4),
      );
      final image = find.descendant(of: cover, matching: find.byType(RawImage));
      ui.Image? decodedImage;
      for (var frame = 0; frame < 10 && decodedImage == null; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        decodedImage = tester.widget<RawImage>(image).image;
      }
      expect(decodedImage, isNotNull);
      final targetWidth = (displayWidth * devicePixelRatio).round();
      final decodedBytes = decodedImage!.width * decodedImage.height * 4;
      expect(decodedImage.width, targetWidth);
      expect(decodedImage.height, targetWidth * sourceHeight ~/ sourceWidth);
      expect(decodedBytes, lessThan(sourceWidth * sourceHeight * 4 ~/ 40));
    } finally {
      debugNetworkImageHttpClientProvider = previousHttpClientProvider;
    }
  });

  testWidgets(
    'cover badges occupy their requested corners and metadata opens its catalog',
    (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
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
      final title = tester.getRect(find.text(_video.title));
      final titleText = tester.widget<Text>(find.text(_video.title));
      expect(titleText.style?.fontSize, 12);
      expect(titleText.style?.height, 1.1);
      final release = tester.getRect(
        find.byKey(const ValueKey('video-release-sample')),
      );
      expect(duration.top, greaterThan(title.bottom));
      expect(duration.top, greaterThan(cover.bottom));
      expect(cover.contains(duration.center), isFalse);
      final durationText = tester.widget<Text>(find.text('01:02:03'));
      expect(durationText.style?.fontSize, 10);
      expect(durationText.style?.color, Colors.blue[700]);
      expect(durationText.style?.fontWeight, FontWeight.w500);
      expect(release.center.dx, greaterThan(cover.center.dx));
      expect(release.center.dy, greaterThan(cover.center.dy));
      final releaseText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('video-release-sample')),
          matching: find.byType(Text),
        ),
      );
      expect(releaseText.style?.fontSize, 10);
      expect(releaseText.style?.fontWeight, FontWeight.bold);
      for (final icon in [Icons.closed_caption, Icons.no_encryption_outlined]) {
        final bounds = tester.getRect(find.byIcon(icon));
        expect(bounds.center.dx, lessThan(cover.center.dx));
        expect(bounds.center.dy, greaterThan(cover.center.dy));
      }
      expect(
        tester.getRect(find.text('Sample actor')).top,
        greaterThan(cover.bottom),
      );
      final colors = Theme.of(
        tester.element(find.text('Sample actor')),
      ).colorScheme;
      final actorChipColors = tester
          .widgetList<Material>(
            find.ancestor(
              of: find.text('Sample actor'),
              matching: find.byType(Material),
            ),
          )
          .map((material) => material.color)
          .toSet();
      final tagChipColors = tester
          .widgetList<Material>(
            find.ancestor(
              of: find.text('Drama'),
              matching: find.byType(Material),
            ),
          )
          .map((material) => material.color)
          .toSet();
      expect(actorChipColors, contains(colors.tertiaryContainer));
      expect(tagChipColors, contains(colors.primaryContainer));
      expect(tester.widget<Text>(find.text('Drama')).style?.fontSize, 10);
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
      expect(find.byKey(const ValueKey('video-number-empty')), findsNothing);
      expect(find.text('Title only'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dense metadata stays compact and exposes the remaining entries',
    (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var opened = false;
      VideoLink? openedLink;
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
                onOpenLink: (link) => openedLink = link,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Actress A'), findsOneWidget);
      expect(find.text('Actress C'), findsNothing);
      expect(find.text('Tag 3'), findsOneWidget);
      expect(find.text('Tag 4'), findsOneWidget);
      expect(find.text('Tag 8'), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('+5'), findsNothing);
      await tester.tap(find.text('Tag 8'));
      expect(openedLink?.url, video.cardTags.last.url);
      await tester.tap(find.text('+2'));
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
      final title = tester.widget<Text>(find.text(_video.title));
      expect(title.style?.fontSize, 14);
      expect(title.style?.height, 1.3);
      expect(actress.left, greaterThan(cover.right));
      expect(
        actress.top,
        greaterThan(
          tester
              .getRect(find.byKey(const ValueKey('video-duration-sample')))
              .bottom,
        ),
      );
      expect(
        tester.widget<Text>(find.text('Sample actor')).style?.fontSize,
        11,
      );
      expect(tester.widget<Text>(find.text('Drama')).style?.fontSize, 11);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'duration follows other information and precedes actors in every layout',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        for (final field in [
          VideoCardField.makers,
          VideoCardField.labels,
          VideoCardField.series,
          VideoCardField.directors,
        ])
          'video_card_display_${field.name}': true,
      });
      tester.view.physicalSize = const Size(400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final video = _richVideo();
      for (final layout in LayoutType.values) {
        await tester.pumpWidget(
          _app(
            Center(
              child: SizedBox(
                width: 280,
                child: VideoCard(
                  video: video,
                  layoutType: layout,
                  subtitle: 'Source note',
                  onTap: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final strings = S.of(tester.element(find.byType(VideoCard)));
        final rows = [
          find.text(video.title),
          find.text('Source note'),
          find.text('${strings.videoCardMakers}: Studio A'),
          find.text('${strings.videoCardLabels}: Label A'),
          find.text('${strings.series}: Series A'),
          find.text('${strings.videoCardDirectors}: Director A'),
          find.byKey(const ValueKey('video-duration-rich')),
          find.text('Actress A'),
          find.text('Tag 1'),
        ];
        for (var index = 1; index < rows.length; index++) {
          expect(
            tester.getRect(rows[index]).top,
            greaterThanOrEqualTo(tester.getRect(rows[index - 1]).bottom),
            reason: '$layout row $index',
          );
        }
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('saved tags keep source labels and links across app languages', (
    tester,
  ) async {
    final video = VideoItem.fromJson({
      'id': 'localized',
      'title': 'Saved video',
      'pageUrl': 'https://missav.ai/ja/localized',
      'tags': [
        for (final (label, url) in [
          ('ハイビジョン', 'https://missav.ai/ja/genres/ハイビジョン'),
          ('高清', 'https://missav.ai/cn/genres/高清'),
          ('独占配信', 'https://missav.ai/ja/genres/独占配信'),
          ('Unknown genre', 'https://missav.ai/ja/genres/unknown'),
        ])
          VideoLink(
            label: label,
            url: url,
            kind: VideoLinkKind.category,
          ).toJson(),
      ],
    });
    final storedJson = video.toJson();
    VideoLink? opened;
    for (final locale in [
      const Locale('en'),
      const Locale('zh'),
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      const Locale('ja'),
    ]) {
      await tester.pumpWidget(
        _app(
          Center(
            child: SizedBox(
              width: 280,
              child: VideoCard(
                video: video,
                layoutType: LayoutType.bigGrid,
                onTap: () {},
                onOpenLink: (link) => opened = link,
              ),
            ),
          ),
          locale: locale,
        ),
      );
      await tester.pumpAndSettle();
      for (final tag in video.tags) {
        expect(find.text(tag.label), findsOneWidget);
        await tester.tap(find.text(tag.label));
        expect(opened, same(tag));
        expect(opened?.url, tag.url);
      }
      expect(video.toJson(), storedJson);
    }
  });

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

  testWidgets('visible cover reports follow layout and resized viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final videos = [
      for (var index = 0; index < 24; index++)
        VideoItem(
          id: 'visible-$index',
          title: 'Visible video $index',
          pageUrl: 'https://missav.ai/en/visible-$index',
        ),
    ];

    for (final layout in LayoutType.values) {
      tester.view.physicalSize = const Size(360, 800);
      final reports = <({List<String> ids, int? cacheWidth})>[];
      Widget collection() => _app(
        SizedBox.expand(
          child: VideoCollectionView<VideoItem>(
            items: videos,
            layoutType: layout,
            itemId: (video) => video.id,
            itemBuilder: (_, video, _) =>
                VideoCard(video: video, layoutType: layout, onTap: null),
            controller: controller,
            pageStorageKey: PageStorageKey<String>('visible-$layout'),
            emptyBuilder: (_) => const SizedBox.shrink(),
            onVisibleItemsChanged: (items, cacheWidth) => reports.add((
              ids: items.map((video) => video.id).toList(),
              cacheWidth: cacheWidth,
            )),
          ),
        ),
      );

      await tester.pumpWidget(collection());
      await tester.pump();
      expect(reports, isNotEmpty, reason: '$layout initial viewport');
      final initial = reports.last;
      expect(initial.ids, isNotEmpty);
      expect(initial.ids.length, lessThan(videos.length));
      expect(initial.cacheWidth, greaterThan(0));

      tester.view.physicalSize = const Size(840, 360);
      await tester.pumpWidget(collection());
      await tester.pump();
      expect(reports.length, greaterThan(1), reason: '$layout resize');
      final resized = reports.last;
      expect(resized.ids, isNotEmpty);
      expect(resized.ids.length, lessThan(videos.length));
      if (layout != LayoutType.list) {
        expect(resized.cacheWidth, isNot(initial.cacheWidth));
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
    await _savePreview(tester, boundary, 'build/video-card-layout-preview.png');
    final notifier = ProviderScope.containerOf(
      tester.element(find.byType(VideoCard).first),
    ).read(videoCardDisplayProvider.notifier);
    for (final field in [
      VideoCardField.makers,
      VideoCardField.labels,
      VideoCardField.series,
      VideoCardField.directors,
    ]) {
      await notifier.setVisible(field, true);
    }
    await tester.pumpAndSettle();
    await _savePreview(
      tester,
      boundary,
      'build/video-card-information-order-preview.png',
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _savePreview(
  WidgetTester tester,
  RenderRepaintBoundary boundary,
  String path,
) => tester.runAsync(() async {
  final image = await boundary.toImage(pixelRatio: 1);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  await Directory('build').create(recursive: true);
  await File(path).writeAsBytes(
    data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
});

Widget _app(
  Widget child, {
  double textScale = 1,
  Locale locale = const Locale('en'),
}) => ProviderScope(
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: locale,
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
  ),
);

class _VideoCoverHttpClient implements HttpClient {
  _VideoCoverHttpClient(this._body);

  final Uint8List _body;

  @override
  bool autoUncompress = false;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _VideoCoverHttpRequest(_body);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _VideoCoverHttpRequest implements HttpClientRequest {
  _VideoCoverHttpRequest(this._body);

  final Uint8List _body;

  @override
  final HttpHeaders headers = _VideoCoverHttpHeaders();

  @override
  Future<HttpClientResponse> close() async => _VideoCoverHttpResponse(_body);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _VideoCoverHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _VideoCoverHttpResponse(this._body)
    : headers = _VideoCoverHttpHeaders({
        HttpHeaders.contentTypeHeader: 'image/png',
        HttpHeaders.contentLengthHeader: _body.length.toString(),
      });

  final Uint8List _body;

  @override
  final HttpHeaders headers;

  @override
  int get contentLength => _body.length;

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => 'OK';

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_body).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _VideoCoverHttpHeaders implements HttpHeaders {
  _VideoCoverHttpHeaders([Map<String, String> values = const {}])
    : _values = {
        for (final entry in values.entries)
          entry.key.toLowerCase(): <String>[entry.value],
      };

  final Map<String, List<String>> _values;

  @override
  String? value(String name) => _values[name.toLowerCase()]?.join(', ');

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values.putIfAbsent(name.toLowerCase(), () => []).add(value.toString());
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = [value.toString()];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
