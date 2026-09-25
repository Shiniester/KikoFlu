import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/comics/comic_downloads.dart';
import 'package:kikoeru_flutter/src/comics/comic_http.dart';
import 'package:kikoeru_flutter/src/comics/comic_library.dart';
import 'package:kikoeru_flutter/src/comics/comic_models.dart';
import 'package:kikoeru_flutter/src/comics/comic_source.dart';

class _Library extends ComicLibrary {
  final saved = <String, Map<String, dynamic>>{};
  @override
  Future<List<Map<String, dynamic>>> loadTasks() async => saved.values.toList();
  @override
  Future<void> saveTask(String id, Map<String, dynamic> task) async {
    saved[id] = task;
  }

  @override
  Future<void> deleteTask(String id) async {
    saved.remove(id);
  }
}

class _Source extends ComicSource {
  _Source() : super(ComicHttp('fixture'));
  @override
  String get key => 'fixture';
  @override
  String get name => 'Fixture';
  @override
  String get website => 'https://fixture.invalid';
  @override
  Future<ComicResult> search(
    String query, {
    String? cursor,
    String? sort,
  }) async => const ComicResult([]);
  @override
  Future<Comic> details(String id) async => book;
  @override
  Future<List<ComicPage>> pages(Comic comic, ComicChapter chapter) async =>
      const [ComicPage('one'), ComicPage('two')];
}

const chapter = ComicChapter('chapter', 'Chapter');
const book = Comic(
  source: 'fixture',
  id: 'book',
  title: 'Book',
  chapters: [chapter],
);

Future<void> until(ComicDownloads downloads, bool Function() done) async {
  if (done()) return;
  final signal = Completer<void>();
  void listener() {
    if (done() && !signal.isCompleted) signal.complete();
  }

  downloads.addListener(listener);
  try {
    await signal.future.timeout(const Duration(seconds: 5));
  } finally {
    downloads.removeListener(listener);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Library library;
  late _Source source;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('kikoflu-comic-test-');
    SharedPreferences.setMockInitialValues({
      'comic_download_directory': root.path,
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    library = _Library();
    source = _Source();
  });
  tearDown(() async {
    library.dispose();
    source.http.dispose();
    await root.delete(recursive: true);
  });

  test(
    'failed page retries without redownloading completed pages; missing file is not complete',
    () async {
      var fail = true;
      final calls = <String>[];
      final downloads = ComicDownloads(
        library,
        (_) => source,
        imageLoader: (_, page) async {
          calls.add(page.url);
          if (page.url == 'two' && fail) throw StateError('offline');
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      await downloads.enqueue(book, [chapter]);
      await until(
        downloads,
        () => downloads.tasks.single.status == ComicDownloadStatus.failed,
      );
      expect(downloads.completedComics, isEmpty);
      expect(downloads.tasks.single.completed, 1);
      fail = false;
      await downloads.resume(downloads.tasks.single);
      await until(
        downloads,
        () => downloads.tasks.single.status == ComicDownloadStatus.complete,
      );
      expect(calls.where((url) => url == 'one').length, 1);
      final offline = await downloads.offlinePages(book, chapter);
      expect(await File(offline!.last.localPath!).readAsBytes(), [1, 2, 3]);
      await File(offline.first.localPath!).delete();
      expect(await downloads.offlinePages(book, chapter), isNull);
      expect(downloads.completedComics, isEmpty);
      await downloads.remove(downloads.tasks.single);
      expect(library.saved, isEmpty);
      downloads.dispose();
    },
  );

  test(
    'pause during an image request cannot mark a chapter complete',
    () async {
      final started = Completer<void>();
      final bytes = Completer<Uint8List>();
      final downloads = ComicDownloads(
        library,
        (_) => source,
        imageLoader: (_, page) {
          if (!started.isCompleted) started.complete();
          return bytes.future;
        },
      );
      await downloads.enqueue(book, [chapter]);
      await started.future;
      final task = downloads.tasks.single;
      await downloads.pause(task);
      bytes.complete(Uint8List.fromList([1]));
      await downloads.remove(task);
      expect(downloads.completedComics, isEmpty);
      expect(downloads.tasks, isEmpty);
      downloads.dispose();
    },
  );
}
