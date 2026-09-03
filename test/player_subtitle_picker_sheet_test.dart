import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/player_subtitle_candidates_provider.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_subtitle_picker_sheet.dart';

void main() {
  testWidgets('subtitle picker prioritizes matches and can show whole work', (
    tester,
  ) async {
    const currentSource = LyricSourceDescriptor(
      title: 'current.srt',
      type: LyricSourceType.localFile,
      localPath: r'C:\captions\current.srt',
      workId: 7,
    );
    const candidates = <PlayerSubtitleCandidate>[
      PlayerSubtitleCandidate(
        identity: r'local:c:\captions\current.srt',
        title: 'current.srt',
        pathLabel: 'Saved/current.srt',
        origin: PlayerSubtitleCandidateOrigin.library,
        source: {
          'title': 'current.srt',
          'localPath': r'C:\captions\current.srt',
          'workId': 7,
        },
        matchesCurrentAudio: true,
        matchScore: 1,
        sameDirectory: false,
      ),
      PlayerSubtitleCandidate(
        identity: 'hash:other',
        title: 'other-track.vtt',
        pathLabel: 'Disc 2/other-track.vtt',
        origin: PlayerSubtitleCandidateOrigin.work,
        source: {'title': 'other-track.vtt', 'hash': 'other', 'workId': 7},
        matchesCurrentAudio: false,
        matchScore: 0,
        sameDirectory: false,
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerSubtitleCandidatesProvider.overrideWith(
            (ref) async => candidates,
          ),
          lyricControllerProvider.overrideWith(
            (ref) => LyricController(
              ref,
              initialState: LyricState(source: currentSource),
            ),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPlayerSubtitlePickerSheet(context),
                child: const Text('open picker'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open picker'));
    await tester.pumpAndSettle();
    expect(find.text('Select subtitles'), findsOneWidget);
    expect(find.text('current.srt'), findsOneWidget);
    expect(find.text('other-track.vtt'), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('player-subtitle-show-all')));
    await tester.pumpAndSettle();
    expect(find.text('other-track.vtt'), findsOneWidget);
    expect(find.textContaining('Work files'), findsOneWidget);
  });
}
