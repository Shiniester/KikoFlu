import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/services/download_file_path_service.dart';
import 'package:kikoeru_flutter/src/services/work_track_file_builder.dart';
import 'package:kikoeru_flutter/src/utils/file_tree_utils.dart';

void main() {
  test('keeps chapter bounds through bulk-download and offline metadata', () {
    const builder = WorkTrackFileBuilder(host: '', token: '');
    final chapter = builder.toAudioFiles([
      {
        'type': 'audio',
        'title': 'Chapter 2.aac',
        'hash': 'jp-151514-chapter-425000',
        'mediaStreamUrl': 'https://v.weeab0o.xyz/RJ01737373.m3u8',
        'startTimeMs': 425000,
        'endTimeMs': 1313000,
        'duration': 888,
      },
    ]).single;
    final restored = AudioFile.fromJson(chapter.toJson());

    expect(restored.type, 'file');
    expect(restored.isAudio, isTrue);
    expect(restored.mediaDownloadUrl, 'https://v.weeab0o.xyz/RJ01737373.m3u8');
    expect(restored.duration, 888);
    final offlineMetadata =
        DownloadFilePathService.annotateFileTreeWithLocalPaths([chapter]);
    final offlineChapter = AudioFile.fromJson(offlineMetadata.single);
    expect(FileTreeUtils.property(offlineChapter, 'startTimeMs'), 425000);
    expect(FileTreeUtils.property(offlineChapter, 'endTimeMs'), 1313000);
    expect(AudioFile.fromJson(const {'title': 'old.mp3'}).startTimeMs, isNull);
  });

  test('converts API file trees into AudioFile trees', () {
    const builder = WorkTrackFileBuilder(
      host: 'kiko.example',
      token: 'token-1',
    );

    final files = [
      {
        'type': 'folder',
        'title': 'Disc 1',
        'hash': 'folder-hash',
        'children': [
          {
            'type': 'audio',
            'name': 'track01.mp3',
            'hash': 'hash-1',
            'size': 1024,
          },
          {
            'type': 'text',
            'title': 'readme.txt',
            'hash': 'hash-2',
            'mediaStreamUrl': '/custom/media/hash-2',
          },
        ],
      },
    ];

    final audioFiles = builder.toAudioFiles(files);

    expect(audioFiles, hasLength(1));
    expect(audioFiles.first.title, 'Disc 1');
    expect(audioFiles.first.type, 'folder');
    expect(audioFiles.first.mediaDownloadUrl, isNull);

    final children = audioFiles.first.children!;
    expect(children, hasLength(2));
    expect(children.first.title, 'track01.mp3');
    expect(children.first.type, 'file');
    expect(children.first.size, 1024);
    expect(
      children.first.mediaDownloadUrl,
      'https://kiko.example/api/media/stream/hash-1?token=token-1',
    );
    expect(children.last.title, 'readme.txt');
    expect(children.last.mediaDownloadUrl, '/custom/media/hash-2');
  });

  test('keeps existing host schemes and omits fallback URLs without host', () {
    const absoluteHostBuilder = WorkTrackFileBuilder(
      host: 'http://localhost:3000',
      token: 'token-2',
    );

    final audioFiles = absoluteHostBuilder.toAudioFiles([
      {
        'type': 'audio',
        'title': 'track.wav',
        'hash': 'hash-3',
      },
    ]);

    expect(
      audioFiles.single.mediaDownloadUrl,
      'http://localhost:3000/api/media/stream/hash-3?token=token-2',
    );

    const emptyHostBuilder = WorkTrackFileBuilder(host: '', token: 'token-3');
    final offlineFiles = emptyHostBuilder.toAudioFiles([
      {
        'type': 'audio',
        'title': 'track.wav',
        'hash': 'hash-4',
      },
    ]);

    expect(offlineFiles.single.mediaDownloadUrl, isNull);
  });

  test('adds converted tracks while preserving work metadata', () {
    const builder = WorkTrackFileBuilder(
      host: 'kiko.example',
      token: 'token-4',
    );
    const work = Work(
      id: 10,
      title: 'Original Work',
      name: 'Circle',
      progress: 'listened',
      otherLanguageEditions: [
        OtherLanguageEdition(
          id: 11,
          lang: 'en',
          title: 'English Edition',
          sourceId: 'RJ011',
          isOriginal: false,
          sourceType: 'dlsite',
        ),
      ],
    );

    final result = builder.withTracks(
      work: work,
      files: [
        {
          'type': 'audio',
          'title': 'track.flac',
          'hash': 'hash-5',
        },
      ],
    );

    expect(result.id, work.id);
    expect(result.title, work.title);
    expect(result.name, work.name);
    expect(result.progress, work.progress);
    expect(result.otherLanguageEditions, work.otherLanguageEditions);
    expect(result.children, hasLength(1));
    expect(result.children!.single.title, 'track.flac');
  });
}
