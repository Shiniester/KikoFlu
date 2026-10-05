import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/player_work_details_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';
import 'package:kikoeru_flutter/src/widgets/circle_chip.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_audio_details_panel.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_action_icons.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_glass_surface.dart';
import 'package:kikoeru_flutter/src/widgets/responsive_dialog.dart';
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
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'moving audio into a subtitle directory invalidates classification',
    () async {
      final audio = {'type': 'audio', 'title': 'track.wav', 'hash': 'audio'};
      final subtitle = {
        'type': 'text',
        'title': 'track.lrc',
        'hash': 'subtitle',
      };
      final repository = PlayerWorkDetailsRepository();
      Future<PlayerWorkDetailsData> load(List<dynamic> fileTree) =>
          repository.load(
            track: _track,
            fileTree: fileTree,
            canUseRemoteMetadata: false,
            loadRemoteWork: (_) async => throw StateError('must stay offline'),
          );
      final before = await load([
        {
          'type': 'folder',
          'title': '简中',
          'children': [subtitle],
        },
        audio,
      ]);
      final after = await load([
        {
          'type': 'folder',
          'title': '简中',
          'children': [subtitle, audio],
        },
      ]);

      expect(
        before.variants.single.subtitleLanguage,
        PlayerSubtitleLanguage.none,
      );
      expect(
        after.variants.single.subtitleLanguage,
        PlayerSubtitleLanguage.simplifiedChinese,
      );
      expect(after.fileTreeId, isNot(before.fileTreeId));
      expect(repository.debugClassificationCount, 2);
    },
  );

  for (final tapAction in [false, true]) {
    testWidgets(
      'keeps audio list stable while queueing via ${tapAction ? 'action' : 'row'}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(500, 400);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final variants = _CountingVariants(
          const PlayerAudioVariantClassifier().scan(_tree),
        );
        final enqueueCompleter = Completer<PlayerEnqueueVariantResult>();
        final queueController = _PendingVariantQueueController(
          enqueueCompleter,
        );
        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playerWorkDetailsProvider.overrideWith(
                (ref) async => PlayerWorkDetailsData(
                  track: _track,
                  work: _work,
                  fileTree: _tree,
                  variants: variants,
                  fileTreeId: 'queue-fixture',
                ),
              ),
              playerAudioVariantQueueControllerProvider.overrideWith(
                (ref) => queueController,
              ),
            ],
            child: MaterialApp(
              theme: ThemeData.dark(useMaterial3: true),
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: Scaffold(
                body: PlayerBackdropGroup(
                  child: PlayerAudioDetailsPanel(
                    scrollController: scrollController,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final firstVariant = find.byKey(
          ValueKey('player-audio-variant-${variants.first.fullPath}'),
        );
        final secondVariant = find.byKey(
          ValueKey('player-audio-variant-${variants[1].fullPath}'),
        );
        await tester.ensureVisible(secondVariant);
        await tester.pumpAndSettle();
        expect(scrollController.offset, greaterThan(0));
        final initialOffset = scrollController.offset;
        final initialElements = [
          tester.element(firstVariant),
          tester.element(secondVariant),
        ];
        List<Color?> textColors() => [
          for (final row in [firstVariant, secondVariant])
            ...tester
                .widgetList<Text>(
                  find.descendant(of: row, matching: find.byType(Text)),
                )
                .map((text) => text.style?.color),
        ];
        final initialColors = textColors();
        final tapTarget = tapAction
            ? find.descendant(
                of: firstVariant,
                matching: find.byType(PlayerCompactAction),
              )
            : firstVariant;
        final initialReads = variants.reads;

        await tester.tap(tapTarget);
        await tester.pump();

        expect(queueController.callCount, 1);
        expect(variants.reads, initialReads);
        expect(textColors(), initialColors);
        expect(tester.element(firstVariant), same(initialElements[0]));
        expect(tester.element(secondVariant), same(initialElements[1]));
        expect(scrollController.offset, initialOffset);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.tap(tapTarget);
        await tester.tap(secondVariant);
        await tester.pump();
        expect(queueController.callCount, 1);

        enqueueCompleter.complete(
          const PlayerEnqueueVariantResult(PlayerEnqueueVariantStatus.queued),
        );
        await tester.pump();
        expect(variants.reads, initialReads);
        expect(textColors(), initialColors);
        expect(scrollController.offset, initialOffset);
        await tester.tap(tapTarget);
        await tester.pump();
        expect(queueController.callCount, 2);
      },
    );
  }

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

  testWidgets('audio filter uses a responsive sheet without blur', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

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
    final filterSheet = find.byType(ResponsiveBottomSheet);
    expect(filterSheet, findsOneWidget);
    expect(
      find.descendant(of: filterSheet, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    final albumGlass = find.descendant(
      of: find.byKey(const ValueKey('player-detail-album')),
      matching: find.byType(PlayerGlassSurface),
    );
    expect(albumGlass, findsOneWidget);
    expect(
      find.descendant(of: albumGlass, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    expect(find.text('Sound effects'), findsOneWidget);
    expect(find.text('SE'), findsNothing);
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'FLAC'))
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<FilterChip>(
            find.widgetWithText(FilterChip, 'Simplified Chinese'),
          )
          .selected,
      isTrue,
    );
    final filterTitle = tester.widget<Text>(find.text('Filter audio files'));
    expect(filterTitle.style?.fontSize, 18);
    final keywordField = tester.widget<TextField>(find.byType(TextField));
    expect(keywordField.decoration?.isDense, isTrue);

    await tester.enterText(find.byType(TextField), 'track-2');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('track.flac'), findsOneWidget);
    expect(find.text('track-2.flac'), findsOneWidget);
  });

  testWidgets('global audio preference changes restore the synced filter', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final details = PlayerWorkDetailsData(
      track: _track,
      work: _work,
      fileTree: _tree,
      variants: const PlayerAudioVariantClassifier().scan(_tree),
      fileTreeId: 'global-filter-fixture',
    );
    final container = ProviderContainer(
      overrides: [
        playerWorkDetailsProvider.overrideWith((ref) async => details),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: PlayerBackdropGroup(child: PlayerAudioDetailsPanel()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('player-audio-filter-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'track-2');
    await tester.ensureVisible(find.text('Apply'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('track.flac'), findsNothing);
    expect(find.text('track-2.flac'), findsOneWidget);

    await container
        .read(audioFormatPreferenceProvider.notifier)
        .updatePreference(
          container
              .read(audioFormatPreferenceProvider)
              .copyWith(se: PlayerBinaryTrait.absent),
        );
    await tester.pumpAndSettle();
    expect(find.text('track.flac'), findsOneWidget);
    expect(find.text('track-2.flac'), findsOneWidget);
  });

  testWidgets(
    'filtered results update with variants and reset for a new tree',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      PlayerWorkDetailsData details = PlayerWorkDetailsData(
        track: _track,
        work: _work,
        fileTree: _tree,
        variants: const PlayerAudioVariantClassifier().scan(_tree),
        fileTreeId: 'filter-fixture',
      );
      final container = ProviderContainer(
        overrides: [
          playerWorkDetailsProvider.overrideWith((ref) async => details),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: Scaffold(
              body: PlayerBackdropGroup(child: PlayerAudioDetailsPanel()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('player-audio-filter-button')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'track-2');
      await tester.ensureVisible(find.text('Apply'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('track.flac'), findsNothing);
      expect(find.text('track-2.flac'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('player-audio-filter-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect(find.text('track.flac'), findsOneWidget);
      expect(find.text('track-2.flac'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('player-audio-filter-button')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'track-2');
      await tester.ensureVisible(find.text('Apply'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      final newTree = <dynamic>[
        {'type': 'audio', 'title': 'replacement.wav', 'hash': 'replacement'},
      ];
      final newVariants = const PlayerAudioVariantClassifier().scan(newTree);
      details = PlayerWorkDetailsData(
        track: _track,
        work: _work,
        fileTree: newTree,
        variants: newVariants,
        fileTreeId: 'filter-fixture',
      );
      container.invalidate(playerWorkDetailsProvider);
      await tester.pumpAndSettle();
      expect(find.text('No files match these filters'), findsOneWidget);
      expect(find.text('track-2.flac'), findsNothing);

      details = PlayerWorkDetailsData(
        track: _track,
        work: _work,
        fileTree: newTree,
        variants: newVariants,
        fileTreeId: 'new-fixture',
      );
      container.invalidate(playerWorkDetailsProvider);
      await tester.pumpAndSettle();
      expect(find.text('replacement.wav'), findsOneWidget);
      expect(find.text('No files match these filters'), findsNothing);
    },
  );
}

class _CountingVariants extends ListBase<PlayerAudioVariant> {
  _CountingVariants(this._variants);

  final List<PlayerAudioVariant> _variants;
  int reads = 0;

  @override
  int get length => _variants.length;

  @override
  set length(int value) => throw UnsupportedError('Immutable variants');

  @override
  PlayerAudioVariant operator [](int index) {
    reads++;
    return _variants[index];
  }

  @override
  void operator []=(int index, PlayerAudioVariant value) =>
      throw UnsupportedError('Immutable variants');
}

class _PendingVariantQueueController
    implements PlayerAudioVariantQueueController {
  _PendingVariantQueueController(this.enqueueCompleter);

  final Completer<PlayerEnqueueVariantResult> enqueueCompleter;
  int callCount = 0;

  @override
  Future<PlayerEnqueueVariantResult> enqueueNext({
    required PlayerWorkDetailsData details,
    required PlayerAudioVariant variant,
  }) {
    callCount++;
    return enqueueCompleter.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
