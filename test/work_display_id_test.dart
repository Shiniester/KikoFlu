import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/models/history_record.dart';
import 'package:kikoeru_flutter/src/models/work.dart';

void main() {
  test('ASMR.ONE remains the default audio source', () {
    expect(AudioSource.fromValue(null), AudioSource.asmrOne);
  });

  group('Work displayId', () {
    test('uses source_id from official API when present', () {
      final work = Work.fromJson(const {
        'id': 100000061,
        'title': '榊木春乃はアナタだけの配信者',
        'source_id': 'VJ01003041',
      });

      expect(work.sourceId, 'VJ01003041');
      expect(work.displayId, 'VJ01003041');
      expect(work.toJson()['source_id'], 'VJ01003041');
    });

    test('trims source_id before displaying it', () {
      const work = Work(id: 654321, title: 'Trim me', sourceId: '  BJ654321  ');

      expect(work.displayId, 'BJ654321');
    });

    test('falls back to formatted RJ code for legacy payloads', () {
      const workWithoutSourceId = Work(id: 12345, title: 'Legacy');
      const workWithBlankSourceId = Work(
        id: 123456,
        title: 'Blank source id',
        sourceId: '   ',
      );

      expect(workWithoutSourceId.displayId, 'RJ012345');
      expect(workWithBlankSourceId.displayId, 'RJ123456');
    });

    test('copyWith can update source_id display', () {
      const work = Work(id: 12345, title: 'Original');

      expect(work.copyWith(sourceId: 'VJ012345').displayId, 'VJ012345');
    });

    test('Japanese ASMR uses its real source id and external cover', () {
      final work = Work.fromJson(const {
        'id': -1726738,
        'title': 'Example Japanese release',
        'source_id': 'RJ01726738',
        'cover_url': 'https://japaneseasmr.com/covers/RJ01726738.jpg',
      });

      expect(work.isJapaneseAsmr, isTrue);
      expect(work.sourceLabel, 'JP-ASMR');
      expect(work.displayId, 'RJ01726738');
      expect(
        work.getCoverImageUrl('asmr.example', token: 'secret'),
        'https://japaneseasmr.com/covers/RJ01726738.jpg',
      );
      expect(work.toJson()['cover_url'], work.coverUrl);
    });

    test(
      'Japanese fallback cover never targets the configured ASMR server',
      () {
        const work = Work(id: -1234, title: 'No cover yet');

        expect(work.getCoverImageUrl('asmr.example', token: 'secret'), isEmpty);
      },
    );

    test('legacy work history keeps its ID alongside the negative JP ID', () {
      final legacy = Work.fromJson(const {'id': 1726738, 'title': 'Existing'});
      const jp = Work(
        id: -1726738,
        title: 'Japanese ASMR',
        sourceId: 'RJ01726738',
      );
      final timestamp = DateTime.utc(2026);
      final legacyRecord = HistoryRecord(
        work: legacy,
        lastPlayedTime: timestamp,
      );
      final jpRecord = HistoryRecord(work: jp, lastPlayedTime: timestamp);

      expect(Work.fromJson(legacy.toJson()).isJapaneseAsmr, isFalse);
      expect(HistoryRecord.fromMap(legacyRecord.toMap()).work.id, 1726738);
      expect(HistoryRecord.fromMap(jpRecord.toMap()).work.id, -1726738);
      expect(
        legacyRecord.toMap()['work_id'],
        isNot(jpRecord.toMap()['work_id']),
      );
    });
  });
}
