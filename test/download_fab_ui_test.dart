import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/providers/audio_subtitle_generation_provider.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/widgets/download_fab.dart';

const _request = AudioSubtitleRequest(
  track: AudioTrack(id: 'voice', title: 'voice.wav', url: 'file:///voice.wav'),
  fileTree: [],
);

void main() {
  testWidgets(
    'generation FAB opens progress and closing the sheet leaves its job running',
    (tester) async {
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
      controller.enqueue([_request]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioSubtitleGenerationProvider.overrideWith((ref) => controller),
            downloadSummaryProvider.overrideWith(
              (ref) => Stream.value(const DownloadTaskSummary.empty()),
            ),
          ],
          child: _app(const Scaffold(floatingActionButton: DownloadFab())),
        ),
      );
      await tester.pump();

      expect(find.byTooltip('Generate audio subtitles'), findsOneWidget);
      expect(find.byIcon(Icons.download), findsNothing);

      await tester.tap(find.byTooltip('Generate audio subtitles'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('audio-subtitle-generation-jobs')),
        findsOneWidget,
      );
      expect(activeToken?.isCancelled, isFalse);

      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(activeToken?.isCancelled, isFalse);
      expect(
        controller.state.single.status,
        AudioSubtitleGenerationStatus.transcribing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'finished results stay visible until viewed and the notice follows new pages and jobs',
    (tester) async {
      final controller = AudioSubtitleGenerationController(
        (request, token, progress) async => (
          status: AudioSubtitleGenerationStatus.completed,
          path: '/voice.srt',
        ),
      );
      controller.enqueue([_request]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioSubtitleGenerationProvider.overrideWith((ref) => controller),
            downloadSummaryProvider.overrideWith(
              (ref) => Stream.value(const DownloadTaskSummary.empty()),
            ),
          ],
          child: _app(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const Scaffold(floatingActionButton: DownloadFab()),
                    ),
                  ),
                  child: const Text('Other page'),
                ),
              ),
              floatingActionButton: const DownloadFab(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Generate audio subtitles'), findsOneWidget);

      await tester.tap(find.byTooltip('Generate audio subtitles'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('voice.wav'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byTooltip('Generate audio subtitles'), findsNothing);

      await tester.tap(find.text('Other page'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Generate audio subtitles'), findsNothing);

      controller.enqueue([_request]);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Generate audio subtitles'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _app(Widget home) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: S.localizationsDelegates,
  supportedLocales: S.supportedLocales,
  home: home,
);
