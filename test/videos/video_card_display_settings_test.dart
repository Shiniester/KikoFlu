import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/screens/settings_screen.dart';
import 'package:kikoeru_flutter/src/widgets/settings_section.dart';
import 'package:kikoeru_flutter/src/utils/collection_grid_layout.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_collection_view.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_settings_screen.dart';
import 'package:kikoeru_flutter/src/videos/video_card_display_provider.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('settings reaches all eight independent video card switches', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const SettingsScreen()));
    await tester.pumpAndSettle();

    final rootStrings = S.of(tester.element(find.byType(SettingsScreen)));
    final navigationTitles = tester
        .widgetList<SettingsNavigationTile>(find.byType(SettingsNavigationTile))
        .map((tile) => tile.title)
        .toList();
    final comicIndex = navigationTitles.indexOf(rootStrings.comicSettings);
    expect(navigationTitles[comicIndex - 1], rootStrings.audioSettings);
    expect(navigationTitles[comicIndex + 1], rootStrings.videoSettings);
    final videoSettings = find.text(rootStrings.videoSettings);
    await tester.ensureVisible(videoSettings);
    await tester.tap(videoSettings);
    await tester.pumpAndSettle();
    expect(find.byType(VideoSettingsScreen), findsOneWidget);

    final videoStrings = S.of(tester.element(find.byType(VideoSettingsScreen)));
    await tester.tap(find.text(videoStrings.uiSettings));
    await tester.pumpAndSettle();
    expect(find.byType(VideoUiSettingsScreen), findsOneWidget);

    final uiStrings = S.of(tester.element(find.byType(VideoUiSettingsScreen)));
    await tester.tap(find.text(uiStrings.workCardDisplaySettings));
    await tester.pumpAndSettle();
    expect(find.byType(VideoCardDisplaySettingsScreen), findsOneWidget);

    final settingsStrings = S.of(
      tester.element(find.byType(VideoCardDisplaySettingsScreen)),
    );
    final switches = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .toList();
    expect(switches, hasLength(8));
    expect(switches.map((tile) => tile.value), [
      true,
      true,
      true,
      true,
      false,
      false,
      false,
      false,
    ]);

    await tester.tap(find.text(settingsStrings.videoCardMakers));
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile).at(4)).value,
      isTrue,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(VideoUiSettingsScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(VideoSettingsScreen), findsOneWidget);
  });

  testWidgets('card reflects display changes and keeps actors and all tags', (
    tester,
  ) async {
    final video = VideoItem(
      id: 'settings-card',
      title: 'Settings test video',
      pageUrl: 'https://missav.ai/cn/settings-card',
      durationSeconds: 3723,
      releaseDate: '2024-03-02',
      hasSubtitles: true,
      isUncensored: true,
      makers: ['Maker'],
      labels: ['Label'],
      series: ['Series'],
      directors: ['Director'],
      actors: [
        const VideoLink(
          label: 'Actor',
          url: 'https://missav.ai/cn/actresses/actor',
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
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: ListView(
            children: [
              Consumer(
                builder: (context, ref, _) => Wrap(
                  children: [
                    for (final field in [
                      VideoCardField.duration,
                      VideoCardField.releaseDate,
                      VideoCardField.subtitleTag,
                      VideoCardField.uncensoredTag,
                    ])
                      TextButton(
                        key: ValueKey('hide-${field.name}'),
                        onPressed: () => ref
                            .read(videoCardDisplayProvider.notifier)
                            .setVisible(field, false),
                        child: Text(field.name),
                      ),
                    TextButton(
                      key: const ValueKey('show-makers'),
                      onPressed: () => ref
                          .read(videoCardDisplayProvider.notifier)
                          .setVisible(VideoCardField.makers, true),
                      child: const Text('show makers'),
                    ),
                  ],
                ),
              ),
              Center(
                child: SizedBox(
                  width: 120,
                  child: VideoCard(
                    video: video,
                    layoutType: LayoutType.smallGrid,
                    onTap: () {},
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final strings = S.of(tester.element(find.byType(VideoCard)));
    expect(
      find.byKey(const ValueKey('video-duration-settings-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('video-release-settings-card')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.closed_caption), findsOneWidget);
    expect(find.byIcon(Icons.no_encryption_outlined), findsOneWidget);
    expect(find.text('Maker'), findsNothing);
    expect(find.text('Actor'), findsOneWidget);
    expect(find.text('Tag 8'), findsOneWidget);
    final titleRect = tester.getRect(find.text(video.title));
    final durationRect = tester.getRect(
      find.byKey(const ValueKey('video-duration-settings-card')),
    );
    expect(durationRect.top - titleRect.bottom, collectionCardInfoSpacing);

    await tester.tap(find.byKey(const ValueKey('hide-duration')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('video-duration-settings-card')),
      findsNothing,
    );
    expect(
      tester.getRect(find.text('Actor')).top,
      closeTo(titleRect.bottom + collectionCardInfoSpacing + 1, 0.1),
    );

    await tester.tap(find.byKey(const ValueKey('hide-releaseDate')));
    await tester.tap(find.byKey(const ValueKey('hide-subtitleTag')));
    await tester.tap(find.byKey(const ValueKey('hide-uncensoredTag')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('video-release-settings-card')),
      findsNothing,
    );
    expect(find.byIcon(Icons.closed_caption), findsNothing);
    expect(find.byIcon(Icons.no_encryption_outlined), findsNothing);

    await tester.tap(find.byKey(const ValueKey('show-makers')));
    await tester.pump();
    expect(find.text('${strings.videoCardMakers}: Maker'), findsOneWidget);
    expect(find.text('Actor'), findsOneWidget);
    expect(find.text('Tag 8'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(Widget home) => ProviderScope(
  child: MaterialApp(
    locale: const Locale('en'),
    supportedLocales: S.supportedLocales,
    localizationsDelegates: S.localizationsDelegates,
    theme: ThemeData(useMaterial3: true),
    home: home,
  ),
);
