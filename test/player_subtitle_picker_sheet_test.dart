import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/player_subtitle_candidates_provider.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_subtitle_picker_sheet.dart';
import 'package:kikoeru_flutter/src/widgets/responsive_dialog.dart';

void main() {
  testWidgets('responsive subtitle picker keeps options without blur', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

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
    final sheet = find.byType(ResponsiveBottomSheet);
    expect(sheet, findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    expect(find.text('Select subtitles'), findsOneWidget);
    expect(find.text('current.srt'), findsOneWidget);
    expect(find.text('other-track.vtt'), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('player-subtitle-show-all')));
    await tester.pumpAndSettle();
    expect(find.text('other-track.vtt'), findsOneWidget);
    expect(find.textContaining('Work files'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(800, 400);
    await tester.pump();

    await tester.tap(find.text('open picker'));
    await tester.pumpAndSettle();
    final landscapeSheet = find.byType(ResponsiveBottomSheet);
    expect(landscapeSheet, findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    final panel = find
        .descendant(of: landscapeSheet, matching: find.byType(Material))
        .first;
    final panelRect = tester.getRect(panel);
    expect(panelRect.center.dx, closeTo(400, 1));
    expect(panelRect.center.dy, closeTo(200, 1));
    expect(
      find.descendant(
        of: landscapeSheet,
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
  });
}
