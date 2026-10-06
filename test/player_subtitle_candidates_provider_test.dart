import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/player_subtitle_candidates_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Priority extends SubtitleLibraryPriorityNotifier {
  _Priority() {
    state = SubtitleLibraryPriority.lowest;
  }
}

const _track = AudioTrack(
  id: 'audio-hash',
  title: 'scene01.wav',
  url: 'https://example.test/audio',
  workId: 42,
  hash: 'audio-hash',
);

void main() {
  test(
    'merges recursive work subtitles and keeps current source first',
    () async {
      final repository = PlayerSubtitleCandidateRepository(
        libraryLoader: (_) async => const <PlayerSubtitleCandidate>[],
      );
      const lyric = {
        'type': 'text',
        'title': 'scene01.srt',
        'hash': 'subtitle-a',
        'localRelativePath': 'Disc 1/scene01.srt',
        'relativePath': 'Disc 1/scene01.srt',
        'duration': 120,
      };
      final candidates = await repository.load(
        track: _track,
        fileTree: const <dynamic>[
          {
            'type': 'folder',
            'title': 'Disc 1',
            'children': [
              {'type': 'audio', 'title': 'scene01.wav', 'hash': 'audio-hash'},
              lyric,
              {'type': 'text', 'title': 'notes.pdf', 'hash': 'not-subtitle'},
            ],
          },
        ],
        libraryPriority: SubtitleLibraryPriority.highest,
        currentSource: const LyricSourceDescriptor(
          title: 'selected.vtt',
          type: LyricSourceType.localFile,
          localPath: r'C:\captions\selected.vtt',
          workId: 42,
        ),
      );

      expect(candidates.map((item) => item.title), contains('scene01.srt'));
      expect(
        candidates.map((item) => item.title),
        isNot(contains('notes.pdf')),
      );
      expect(candidates.first.title, 'selected.vtt');
      expect(candidates.first.matchesCurrentAudio, isTrue);
      final workCandidate = candidates.singleWhere(
        (candidate) => candidate.title == 'scene01.srt',
      );
      expect(workCandidate.source['localRelativePath'], 'Disc 1/scene01.srt');
      expect(workCandidate.source['relativePath'], 'Disc 1/scene01.srt');
      expect(workCandidate.source['type'], 'text');
      expect(workCandidate.source['duration'], 120);
    },
  );

  test('work query ranks a higher score above a same-folder match', () {
    final candidates = const PlayerSubtitleCandidateRepository()
        .collectWorkCandidates(
          fileTree: const <dynamic>[
            {
              'type': 'folder',
              'title': 'Disc',
              'children': [
                {
                  'type': 'audio',
                  'title': 'abcdefghijklmnopqrst.mp3',
                  'hash': 'audio',
                },
                {
                  'type': 'text',
                  'title': 'abcdefghijklmnopqxyz.srt',
                  'hash': 'lower-score',
                },
              ],
            },
            {
              'type': 'folder',
              'title': 'Bonus',
              'children': [
                {
                  'type': 'text',
                  'title': 'abcdefghijklmnopqrst.lrc',
                  'hash': 'higher-score',
                },
              ],
            },
          ],
          audioTitle: 'abcdefghijklmnopqrst.mp3',
          audioHash: 'audio',
          workId: 42,
        );
    final matching = candidates
        .where((candidate) => candidate.matchesCurrentAudio)
        .toList(growable: false);

    expect(matching.first.title, 'abcdefghijklmnopqrst.lrc');
    expect(matching.first.matchScore, greaterThan(matching.last.matchScore));
    expect(matching.first.sameDirectory, isFalse);
    expect(matching.last.sameDirectory, isTrue);
  });

  test('work query breaks equal scores by folder and then path order', () {
    final candidates = const PlayerSubtitleCandidateRepository()
        .collectWorkCandidates(
          fileTree: const <dynamic>[
            {
              'type': 'folder',
              'title': 'Disc',
              'children': [
                {
                  'type': 'audio',
                  'title': 'abcdefghijklmnopqrst.wav',
                  'hash': 'audio',
                },
                {
                  'type': 'text',
                  'title': 'xbcdefghijklmnopqrst.srt',
                  'hash': 'b',
                },
                {
                  'type': 'text',
                  'title': 'abcdefghijklmnopqrsx.srt',
                  'hash': 'a',
                },
              ],
            },
            {
              'type': 'folder',
              'title': '0-Extras',
              'children': [
                {
                  'type': 'text',
                  'title': 'xbcdefghijklmnopqrst.lrc',
                  'hash': 'extra',
                },
              ],
            },
          ],
          audioTitle: 'abcdefghijklmnopqrst.wav',
          audioHash: 'audio',
          workId: 42,
        )
        .where((candidate) => candidate.matchesCurrentAudio)
        .toList(growable: false);

    expect(candidates.map((candidate) => candidate.title), [
      'abcdefghijklmnopqrsx.srt',
      'xbcdefghijklmnopqrst.srt',
      'xbcdefghijklmnopqrst.lrc',
    ]);
  });

  test(
    'work query keeps the existing match threshold and can return no match',
    () {
      const tree = <dynamic>[
        {'type': 'text', 'title': 'abcdefghijklmnopqxyz.srt'},
        {'type': 'text', 'title': 'abcdefghijklmnopwxyz.srt'},
        {'type': 'text', 'title': 'unrelated.vtt'},
      ];
      const repository = PlayerSubtitleCandidateRepository();

      final candidates = repository.collectWorkCandidates(
        fileTree: tree,
        audioTitle: 'abcdefghijklmnopqrst.mp3',
      );
      final matching = candidates
          .where((candidate) => candidate.matchesCurrentAudio)
          .toList(growable: false);

      expect(matching, hasLength(1));
      expect(matching.single.matchScore, closeTo(0.85, 1e-12));
      expect(
        repository
            .collectWorkCandidates(
              fileTree: tree,
              audioTitle: 'different-audio.mp3',
            )
            .where((candidate) => candidate.matchesCurrentAudio),
        isEmpty,
      );
    },
  );

  test(
    'deduplicates candidates and honors source preference on equal matches',
    () async {
      final repository = PlayerSubtitleCandidateRepository(
        libraryLoader: (_) async => const <PlayerSubtitleCandidate>[
          PlayerSubtitleCandidate(
            identity: 'library:preferred',
            title: 'scene01.srt',
            pathLabel: 'Saved/scene01.srt',
            origin: PlayerSubtitleCandidateOrigin.library,
            source: {'title': 'scene01.srt', 'localPath': 'preferred.srt'},
            matchesCurrentAudio: true,
            matchScore: 1,
            sameDirectory: true,
          ),
          PlayerSubtitleCandidate(
            identity: 'hash:duplicate',
            title: 'duplicate.srt',
            pathLabel: 'Saved/duplicate.srt',
            origin: PlayerSubtitleCandidateOrigin.library,
            source: {'title': 'duplicate.srt', 'hash': 'duplicate'},
            matchesCurrentAudio: false,
            matchScore: 0,
            sameDirectory: false,
          ),
        ],
      );
      final candidates = await repository.load(
        track: _track,
        fileTree: const <dynamic>[
          {'type': 'text', 'title': 'scene01.srt', 'hash': 'work-caption'},
          {'type': 'text', 'title': 'scene01.lrc', 'hash': 'duplicate'},
        ],
        libraryPriority: SubtitleLibraryPriority.highest,
      );

      expect(candidates.first.origin, PlayerSubtitleCandidateOrigin.library);
      expect(
        candidates.where((item) => item.identity == 'hash:duplicate'),
        hasLength(1),
      );
    },
  );

  test(
    'library priority ties retain current source first and origin preference',
    () async {
      final repository = PlayerSubtitleCandidateRepository(
        libraryLoader: (_) async => const <PlayerSubtitleCandidate>[
          PlayerSubtitleCandidate(
            identity: 'library:equal',
            title: 'scene01.srt',
            pathLabel: 'scene01.srt',
            origin: PlayerSubtitleCandidateOrigin.library,
            source: {'title': 'scene01.srt', 'localPath': 'library.srt'},
            matchesCurrentAudio: true,
            matchScore: 1,
            sameDirectory: true,
          ),
        ],
      );
      const currentSource = LyricSourceDescriptor(
        title: 'selected.srt',
        type: LyricSourceType.localFile,
        localPath: r'C:\captions\selected.srt',
        workId: 42,
      );
      const tree = <dynamic>[
        {'type': 'audio', 'title': 'scene01.wav', 'hash': 'audio-hash'},
        {'type': 'text', 'title': 'scene01.srt', 'hash': 'work:equal'},
      ];

      final libraryFirst = await repository.load(
        track: _track,
        fileTree: tree,
        libraryPriority: SubtitleLibraryPriority.highest,
        currentSource: currentSource,
      );
      final workFirst = await repository.load(
        track: _track,
        fileTree: tree,
        libraryPriority: SubtitleLibraryPriority.lowest,
        currentSource: currentSource,
      );

      expect(libraryFirst.first.title, 'selected.srt');
      expect(libraryFirst[1].origin, PlayerSubtitleCandidateOrigin.library);
      expect(workFirst.first.title, 'selected.srt');
      expect(workFirst[1].origin, PlayerSubtitleCandidateOrigin.work);
    },
  );

  test(
    'automatic loading selects the same best work candidate as the query',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp('subtitle-pick-');
      addTearDown(() => directory.delete(recursive: true));
      final lower = File('${directory.path}/lower.srt');
      final higher = File('${directory.path}/higher.lrc');
      await lower.writeAsString('[00:01.00]lower score');
      await higher.writeAsString('[00:01.00]higher score');
      const track = AudioTrack(
        id: 'audio',
        title: 'abcdefghijklmnopqrst.mp3',
        url: 'audio.mp3',
        workId: 42,
        hash: 'audio',
      );
      final fileTree = <dynamic>[
        {
          'type': 'folder',
          'title': 'Disc',
          'children': [
            {'type': 'audio', 'title': track.title, 'hash': track.hash},
            {
              'type': 'text',
              'title': 'abcdefghijklmnopqxyz.srt',
              'hash': 'lower',
              'localPath': lower.path,
            },
          ],
        },
        {
          'type': 'folder',
          'title': 'Bonus',
          'children': [
            {
              'type': 'text',
              'title': 'abcdefghijklmnopqrst.lrc',
              'hash': 'higher',
              'localPath': higher.path,
            },
          ],
        },
      ];
      final expected = const PlayerSubtitleCandidateRepository()
          .collectWorkCandidates(
            fileTree: fileTree,
            audioTitle: track.title,
            audioHash: track.hash,
            workId: track.workId,
          )
          .firstWhere((candidate) => candidate.matchesCurrentAudio);
      final container = ProviderContainer(
        overrides: [
          currentTrackProvider.overrideWith((ref) => Stream.value(track)),
          subtitleLibraryPriorityProvider.overrideWith((ref) => _Priority()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(currentTrackProvider.future);

      await container
          .read(lyricControllerProvider.notifier)
          .loadLyricForTrack(track, fileTree);

      final loaded = container.read(lyricControllerProvider).source;
      expect(loaded?.title, expected.title);
      expect(loaded?.localPath, expected.source['localPath']);
      expect(
        container.read(lyricControllerProvider).lyrics.single.text,
        'higher score',
      );
    },
  );
}
