import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/player_work_details_provider.dart';
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';
import 'package:kikoeru_flutter/src/widgets/circle_chip.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_audio_details_panel.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_action_icons.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_glass_surface.dart';
import 'package:kikoeru_flutter/src/widgets/tag_chip.dart';
import 'package:kikoeru_flutter/src/widgets/va_chip.dart';

const _track = AudioTrack(
  id: 'detail-track',
  title: 'Track',
  url: 'local.flac',
  workId: 7,
);

const _work = Work(
  id: 7,
  title: 'Full album title',
  circleId: 11,
  name: 'Circle name',
  release: '2026-09-01T00:00:00',
  vas: [Va(id: 'va-1', name: 'Voice actor')],
  tags: [Tag(id: 21, name: 'Healing')],
  otherLanguageEditions: [
    OtherLanguageEdition(
      id: 8,
      lang: 'English',
      title: 'Other full album title',
      sourceId: 'RJ000008',
      isOriginal: false,
      sourceType: 'RJ',
    ),
  ],
);

final _tree = <dynamic>[
  {
    'type': 'folder',
    'title': '简中',
    'children': [
      {'type': 'audio', 'title': 'track.flac', 'hash': 'audio'},
      {'type': 'audio', 'title': 'track-2.flac', 'hash': 'audio-2'},
      {'type': 'text', 'title': 'track_简中.lrc', 'hash': 'lyric'},
      {'type': 'text', 'title': 'track-2_简中.lrc', 'hash': 'lyric-2'},
    ],
  },
];

void main() {
  testWidgets('details use dense requested order and existing search chips', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final variants = const PlayerAudioVariantClassifier().scan(_tree);
    Work? opened;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerWorkDetailsProvider.overrideWith(
            (ref) async => PlayerWorkDetailsData(
              track: _track,
              work: _work,
              fileTree: _tree,
              variants: variants,
              fileTreeId: 'detail-fixture',
            ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: PlayerBackdropGroup(
              child: PlayerAudioDetailsPanel(
                onOpenWork: (work) => opened = work,
                isActive: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const orderedKeys = [
      'player-detail-album',
      'player-detail-circle',
      'player-detail-voice-actors',
      'player-detail-audio-files',
      'player-detail-other-editions',
      'player-detail-tags',
    ];
    final tops = orderedKeys
        .map((key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy)
        .toList();
    for (var index = 1; index < tops.length; index++) {
      expect(tops[index], greaterThan(tops[index - 1]));
    }
    final circleTopLeft = tester.getTopLeft(
      find.byKey(const ValueKey('player-detail-circle')),
    );
    final releaseTopLeft = tester.getTopLeft(
      find.byKey(const ValueKey('player-detail-release')),
    );
    expect(releaseTopLeft.dy, closeTo(circleTopLeft.dy, 0.1));
    expect(releaseTopLeft.dx, greaterThan(circleTopLeft.dx));
    expect(
      tester
          .getSize(find.byKey(const ValueKey('player-detail-release')))
          .height,
      closeTo(
        tester
            .getSize(find.byKey(const ValueKey('player-detail-circle')))
            .height,
        0.1,
      ),
    );

    expect(find.byType(CircleChip), findsOneWidget);
    expect(find.byType(VaChip), findsOneWidget);
    expect(find.byType(TagChip), findsOneWidget);
    expect(find.byIcon(Icons.audio_file_outlined), findsNothing);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('RJ000008'), findsOneWidget);
    expect(find.text('Other full album title'), findsNothing);
    final albumSurface = tester.widget<PlayerGlassSurface>(
      find.descendant(
        of: find.byKey(const ValueKey('player-detail-album')),
        matching: find.byType(PlayerGlassSurface),
      ),
    );
    expect(albumSurface.borderColor, Colors.transparent);
    final firstAudio = find.byKey(
      ValueKey('player-audio-variant-${variants[0].fullPath}'),
    );
    final secondAudio = find.byKey(
      ValueKey('player-audio-variant-${variants[1].fullPath}'),
    );
    final playNextButton = find.descendant(
      of: firstAudio,
      matching: find.byType(PlayerCompactAction),
    );
    expect(
      find.descendant(
        of: firstAudio,
        matching: find.byIcon(Icons.skip_next_rounded),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(playNextButton), const Size(32, 32));
    expect(
      tester.getTopLeft(secondAudio).dy,
      closeTo(tester.getBottomLeft(firstAudio).dy, 0.1),
    );

    await tester.tap(find.byKey(const ValueKey('player-detail-album')));
    expect(opened, _work);
  });

  testWidgets('audio filter uses glass and calls SE sound effects', (
    tester,
  ) async {
    final variants = const PlayerAudioVariantClassifier().scan(_tree);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerWorkDetailsProvider.overrideWith(
            (ref) async => PlayerWorkDetailsData(
              track: _track,
              work: _work,
              fileTree: _tree,
              variants: variants,
              fileTreeId: 'filter-fixture',
            ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const Scaffold(
            body: PlayerBackdropGroup(child: PlayerAudioDetailsPanel()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('player-audio-filter-button')));
    await tester.pumpAndSettle();
    expect(find.text('Sound effects'), findsOneWidget);
    expect(find.text('SE'), findsNothing);
    final filterGlass = find.byType(PlayerTransientGlassSurface);
    expect(filterGlass, findsOneWidget);
    expect(
      find.descendant(of: filterGlass, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    final filterTitle = tester.widget<Text>(find.text('Filter audio files'));
    expect(filterTitle.style?.fontSize, 18);
    final keywordField = tester.widget<TextField>(find.byType(TextField));
    expect(keywordField.decoration?.isDense, isTrue);
  });
}
