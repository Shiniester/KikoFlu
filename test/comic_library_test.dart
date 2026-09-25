import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart' as sqlite;
import 'package:kikoeru_flutter/src/comics/comic_library.dart';
import 'package:kikoeru_flutter/src/comics/comic_models.dart';
import 'package:kikoeru_flutter/src/comics/comic_downloads.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final native = Platform.environment['KIKOFLU_TEST_SQLITE'];
  if (native != null) {
    sqlite.open.overrideFor(
      sqlite.OperatingSystem.windows,
      () => DynamicLibrary.open(native),
    );
  }
  sqfliteFfiInit();
  late Database db;
  late ComicLibrary library;
  setUp(() async {
    db = await databaseFactoryFfiNoIsolate.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: ComicLibrary.createSchema,
      ),
    );
    library = ComicLibrary(databaseOpener: () => Future.value(db));
  });
  tearDown(() async {
    library.dispose();
    await db.close();
  });
  test(
    'same IDs from different sources keep independent favorites and progress',
    () async {
      const a = Comic(source: 'picacg', id: '42', title: 'A');
      const b = Comic(source: 'nhentai', id: '42', title: 'B');
      await library.favorite(a, true);
      await library.favorite(b, true);
      await library.saveProgress(a, '2', 7);
      await library.saveProgress(b, '42', 18);
      expect((await library.favorites()).length, 2);
      expect((await library.progress(a))!.page, 7);
      expect((await library.progress(b))!.page, 18);
      await library.favorite(a, false);
      expect(await library.isFavorite(b), true);
      final restarted = ComicLibrary(databaseOpener: () => Future.value(db));
      expect((await restarted.progress(a))!.chapterId, '2');
      restarted.dispose();
    },
  );
  test(
    'restoring an interrupted download pauses it instead of calling it complete',
    () async {
      final task = ComicDownloadTask(
        comic: const Comic(source: 'nhentai', id: '42', title: 'A'),
        chapter: const ComicChapter('42', '1'),
        directory: 'unused',
        status: ComicDownloadStatus.downloading,
        pages: const [ComicPage('https://example/1')],
        completed: 0,
      );
      await library.saveTask(task.id, task.toJson());
      final downloads = ComicDownloads(
        library,
        (_) => throw StateError('offline restore must not request a source'),
      );
      await downloads.ready;
      expect(downloads.tasks.single.status, ComicDownloadStatus.paused);
      expect(downloads.completedComics, isEmpty);
      downloads.dispose();
    },
  );
}
