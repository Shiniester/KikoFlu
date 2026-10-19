import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/audio_subtitle_generation_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/player_subtitle_candidates_provider.dart';
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';
import 'package:kikoeru_flutter/src/services/generated_subtitle_translation_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/audio_subtitle_generation_sheet.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_lyrics_surface.dart';
import 'package:kikoeru_flutter/src/widgets/work_resource_tabs.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _request = AudioSubtitleRequest(
  track: AudioTrack(id: 'voice', title: 'voice.wav', url: 'file:///voice.wav'),
  fileTree: [],
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'lyric_translation_confirmed_once': true,
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  for (final hasVisibleLyrics in [true, false]) {
    testWidgets(
      hasVisibleLyrics
          ? 'existing captions keep the original player subtitle picker'
          : 'the same player button generates and closing the panel keeps work running',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 780);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        CancelToken? activeToken;
        final controller = AudioSubtitleGenerationController((
          request,
          token,
          progress,
        ) async {
          activeToken = token;
          progress(AudioSubtitleGenerationStatus.transcribing, 0.25);
          await token.whenCancel;
          return (status: AudioSubtitleGenerationStatus.cancelled, path: null);
        });
        late _Actions actions;
        final container = ProviderContainer(
          overrides: [
            audioSubtitleGenerationProvider.overrideWith((ref) => controller),
            audioSubtitleActionsProvider.overrideWith((ref) {
              actions = _Actions(ref, controller);
              return actions;
            }),
            positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
            playerSubtitleCandidatesProvider.overrideWith((ref) async => []),
            lyricControllerProvider.overrideWith(
              (ref) => LyricController(
                ref,
                initialState: LyricState(
                  lyrics: hasVisibleLyrics
                      ? [
                          LyricLine(
                            startTime: Duration.zero,
                            endTime: const Duration(seconds: 2),
                            text: 'こんにちは',
                          ),
                        ]
                      : [],
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.read(audioSubtitleActionsProvider);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: _app(
              const PlayerLyricsSurface(
                isWide: false,
                onFullscreen: _noop,
                translateButton: Icon(Icons.translate),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('lyric-subtitle-picker-button')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        if (hasVisibleLyrics) {
          expect(actions.calls, 0);
          expect(find.text('Select subtitles'), findsOneWidget);
          expect(controller.state, isEmpty);
        } else {
          expect(actions.calls, 1);
          expect(find.text('Generate audio subtitles'), findsOneWidget);
          expect(find.text('voice.wav'), findsOneWidget);
          await tester.tap(find.byTooltip('Close'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(activeToken!.isCancelled, isFalse);
          expect(
            controller.state.single.status,
            AudioSubtitleGenerationStatus.transcribing,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'long press receives every filtered audio beyond the viewport with its directory',
    (tester) async {
      final files = <dynamic>[
        for (var index = 0; index < 40; index++)
          {
            'type': 'folder',
            'title': 'Disc $index',
            'children': [
              {
                'type': 'audio',
                'title': 'track$index.wav',
                'hash': 'wav$index',
              },
              {
                'type': 'audio',
                'title': 'track$index.mp3',
                'hash': 'mp3$index',
              },
            ],
          },
      ];
      List<PlayerAudioVariant>? received;
      await tester.pumpWidget(
        ProviderScope(
          child: _app(
            CustomScrollView(
              slivers: [
                WorkResourceTabs(
                  workId: 42,
                  fileTree: files,
                  audioVariants: const PlayerAudioVariantClassifier().scan(
                    files,
                  ),
                  resourceSliver: const SliverToBoxAdapter(
                    child: Text('resources'),
                  ),
                  resourceTitle: 'Resources',
                  onPlayAudio: (_, _, _) {},
                  onFileTap: (_, _, _) {},
                  resolveImage: (_) async => null,
                  onImageTap: (_) {},
                  onAudioLongPress: (_, _, _, _, variants) =>
                      received = variants,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('track39.wav'), findsNothing);
      expect(
        find.byKey(const ValueKey('work-resource-generate-all-subtitles')),
        findsNothing,
      );
      await tester.longPress(find.text('track0.wav'));
      expect(received, hasLength(40));
      expect(
        received!.every((variant) => variant.format == AudioFormat.wav),
        isTrue,
      );
      expect(
        received!.map((variant) => variant.parentPath).toSet(),
        hasLength(40),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'generation asks for translation confirmation once and cancel does not start',
    (tester) async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('lyric_translation_confirmed_once', false);
      final controller = AudioSubtitleGenerationController((
        request,
        token,
        progress,
      ) async {
        await token.whenCancel;
        return (status: AudioSubtitleGenerationStatus.cancelled, path: null);
      });
      late _Actions actions;
      final container = ProviderContainer(
        overrides: [
          audioSubtitleGenerationProvider.overrideWith((ref) => controller),
          audioSubtitleActionsProvider.overrideWith(
            (ref) => actions = _Actions(ref, controller),
          ),
          positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
          lyricControllerProvider.overrideWith(
            (ref) => LyricController(ref, initialState: LyricState()),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(audioSubtitleActionsProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(
            const PlayerLyricsSurface(
              isWide: false,
              onFullscreen: _noop,
              translateButton: Icon(Icons.translate),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('lyric-subtitle-picker-button')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.textContaining('Generated subtitle text will be sent'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(actions.calls, 0);
      await tester.tap(
        find.byKey(const ValueKey('lyric-subtitle-picker-button')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(actions.calls, 1);
      expect(preferences.getBool('lyric_translation_confirmed_once'), isTrue);
      controller.cancelAll();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'translation failure can retry without generating the audio again',
    (tester) async {
      var generated = 0;
      var translated = 0;
      final controller = AudioSubtitleGenerationController(
        (request, token, progress) async {
          generated++;
          return (
            status: AudioSubtitleGenerationStatus.completed,
            path: '/generated.srt',
          );
        },
        translationRunner: (path, token, progress) async {
          if (++translated == 1) throw StateError('translation unavailable');
          return const GeneratedSubtitleTranslation(
            original: [],
            translated: [],
          );
        },
      );
      final container = ProviderContainer(
        overrides: [
          audioSubtitleGenerationProvider.overrideWith((ref) => controller),
        ],
      );
      addTearDown(container.dispose);
      controller.enqueue([_request]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showAudioSubtitleGenerationSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Original subtitles saved. Translation failed; retry translation.',
        ),
        findsOneWidget,
      );
      expect(controller.state.single.path, '/generated.srt');
      await tester.tap(find.byTooltip('Retry translation'));
      await tester.pumpAndSettle();
      expect(generated, 1);
      expect(translated, 2);
      expect(
        controller.state.single.status,
        AudioSubtitleGenerationStatus.completed,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'generation progress stays usable on a short landscape screen with larger text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(780, 360);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = AudioSubtitleGenerationController((
        request,
        token,
        progress,
      ) async {
        await token.whenCancel;
        return (status: AudioSubtitleGenerationStatus.cancelled, path: null);
      });
      final container = ProviderContainer(
        overrides: [
          audioSubtitleGenerationProvider.overrideWith((ref) => controller),
        ],
      );
      addTearDown(container.dispose);
      controller.enqueue([_request]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAudioSubtitleGenerationSheet(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Close'), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('audio-subtitle-generation-jobs')),
        const Offset(0, -400),
      );
      await tester.pump();
      await tester.tap(find.text('Cancel all').hitTestable());
      await tester.pump();
      expect(
        controller.state.single.status,
        AudioSubtitleGenerationStatus.cancelled,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Widget _app(Widget body) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: S.localizationsDelegates,
  supportedLocales: S.supportedLocales,
  home: Scaffold(body: body),
);

void _noop() {}

class _Actions extends AudioSubtitleActions {
  _Actions(super.ref, this.controller);

  final AudioSubtitleGenerationController controller;
  int calls = 0;

  @override
  Future<bool?> startCurrentTrack({
    Future<bool> Function()? beforeGenerate,
  }) async {
    if (beforeGenerate != null && !await beforeGenerate()) return null;
    calls++;
    controller.enqueue([_request]);
    return true;
  }
}
