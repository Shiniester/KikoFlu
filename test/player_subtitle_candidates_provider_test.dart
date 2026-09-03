import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/player_subtitle_candidates_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';

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
      final candidates = await repository.load(
        track: _track,
        fileTree: const <dynamic>[
          {
            'type': 'folder',
            'title': 'Disc 1',
            'children': [
              {'type': 'audio', 'title': 'scene01.wav', 'hash': 'audio-hash'},
              {'type': 'text', 'title': 'scene01.srt', 'hash': 'subtitle-a'},
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
}
