import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../services/storage_service.dart';
import '../services/log_service.dart';
import 'comic_library.dart';
import 'comic_models.dart';
import 'comic_source.dart';
import 'comic_images.dart';

enum ComicDownloadStatus { queued, downloading, paused, failed, complete }

class ComicDownloadTask {
  ComicDownloadTask({
    required this.comic,
    required this.chapter,
    required this.directory,
    this.status = ComicDownloadStatus.queued,
    this.pages = const [],
    this.completed = 0,
    this.error,
    this.coverPath,
  });
  final Comic comic;
  final ComicChapter chapter;
  final String directory;
  ComicDownloadStatus status;
  List<ComicPage> pages;
  int completed;
  String? error;
  String? coverPath;
  String get id => jsonEncode([comic.source, comic.id, chapter.id]);
  Map<String, dynamic> toJson() => {
    'comic': comic.toJson(),
    'chapter': chapter.toJson(),
    'directory': directory,
    'status': status.name,
    'pages': pages.map((p) => p.toJson()).toList(),
    'completed': completed,
    'error': error,
    'coverPath': coverPath,
  };
  factory ComicDownloadTask.fromJson(Map<String, dynamic> j) =>
      ComicDownloadTask(
        comic: Comic.fromJson(j['comic']),
        chapter: ComicChapter.fromJson(j['chapter']),
        directory: j['directory'],
        status: ComicDownloadStatus.values.byName(j['status']),
        pages: (j['pages'] as List).map((v) => ComicPage.fromJson(v)).toList(),
        completed: j['completed'],
        error: j['error'],
        coverPath: j['coverPath'],
      );
  String pathFor(int index) => p.join(directory, '$index.image');
}

class ComicDownloads extends ChangeNotifier {
  ComicDownloads(this.library, this.sourceFor, {this.imageLoader}) {
    ready = _restore();
  }
  final ComicImageLoader? imageLoader;
  final ComicLibrary library;
  final ComicSource Function(String) sourceFor;
  late final Future<void> ready;
  final List<ComicDownloadTask> tasks = [];
  CancelToken? _cancel;
  String? _activeId;
  Future<void>? _running;
  Completer<void>? _activeTask;
  bool _disposed = false;
  Future<void> _restore() async {
    tasks.addAll((await library.loadTasks()).map(ComicDownloadTask.fromJson));
    for (final task in tasks) {
      if (task.status == ComicDownloadStatus.downloading ||
          task.status == ComicDownloadStatus.queued) {
        task.status = ComicDownloadStatus.paused;
      }
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String component(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');
  Future<void> enqueue(Comic comic, List<ComicChapter> chapters) async {
    await ready;
    final root =
        StorageService.getString('comic_download_directory') ??
        p.join(
          (await getApplicationSupportDirectory()).path,
          'comic_downloads',
        );
    for (final chapter in chapters) {
      if (tasks.any(
        (t) => t.comic.key == comic.key && t.chapter.id == chapter.id,
      )) {
        continue;
      }
      final task = ComicDownloadTask(
        comic: comic,
        chapter: chapter,
        directory: p.join(
          root,
          comic.source,
          component(comic.id),
          component(chapter.id),
        ),
      );
      tasks.add(task);
      await library.saveTask(task.id, task.toJson());
    }
    _notify();
    _start();
  }

  void _start() {
    if (_disposed || _running != null) return;
    _running = _drain().whenComplete(() {
      _running = null;
      if (!_disposed &&
          tasks.any((t) => t.status == ComicDownloadStatus.queued)) {
        _start();
      }
    });
  }

  Future<void> _drain() async {
    while (!_disposed) {
      final queued = tasks.where((t) => t.status == ComicDownloadStatus.queued);
      if (queued.isEmpty) return;
      final task = queued.first;
      _activeId = task.id;
      _activeTask = Completer<void>();
      _cancel = CancelToken();
      task.status = ComicDownloadStatus.downloading;
      task.error = null;
      _notify();
      try {
        final source = sourceFor(task.comic.source);
        task.pages = await source.pages(task.comic, task.chapter);
        task.completed = 0;
        if (task.pages.isEmpty) {
          throw const ComicSourceException('This chapter has no pages.');
        }
        await Directory(task.directory).create(recursive: true);
        for (var i = 0; i < task.pages.length; i++) {
          if (task.status != ComicDownloadStatus.downloading || _disposed) {
            break;
          }
          final target = File(task.pathFor(i));
          if (!await target.exists()) {
            final bytes = imageLoader != null
                ? await imageLoader!(source, task.pages[i])
                : await loadComicImage(
                    source.http,
                    task.pages[i],
                    cancelToken: _cancel,
                  );
            if (task.status != ComicDownloadStatus.downloading || _disposed) {
              break;
            }
            final temp = File('${target.path}.part');
            await temp.writeAsBytes(bytes, flush: true);
            await temp.rename(target.path);
          }
          task.completed = i + 1;
          await library.saveTask(task.id, task.toJson());
          _notify();
        }
        if (task.status == ComicDownloadStatus.downloading &&
            task.completed == task.pages.length) {
          if (task.comic.cover.isNotEmpty) {
            try {
              final cover = ComicPage(task.comic.cover);
              final bytes = imageLoader != null
                  ? await imageLoader!(source, cover)
                  : await loadComicImage(
                      source.http,
                      cover,
                      cancelToken: _cancel,
                    );
              final file = File(p.join(task.directory, 'cover.image'));
              await file.writeAsBytes(bytes, flush: true);
              task.coverPath = file.path;
            } catch (_) {
              // A cover failure does not invalidate downloaded chapter pages.
            }
          }
          if (task.status == ComicDownloadStatus.downloading) {
            task.status = ComicDownloadStatus.complete;
          }
        }
      } catch (e) {
        if (task.status != ComicDownloadStatus.paused) {
          task.status = ComicDownloadStatus.failed;
          task.error = e.toString();
        }
      } finally {
        try {
          await library.saveTask(task.id, task.toJson());
        } catch (error) {
          task.status = ComicDownloadStatus.failed;
          task.error = error.toString();
          LogService.instance.error(
            'Comic download persistence: $error',
            tag: 'Comics',
          );
        } finally {
          _activeTask?.complete();
          _activeTask = null;
          _activeId = null;
          _cancel = null;
          _notify();
        }
      }
    }
  }

  Future<void> pause(ComicDownloadTask task) async {
    task.status = ComicDownloadStatus.paused;
    if (_activeId == task.id) _cancel?.cancel();
    await library.saveTask(task.id, task.toJson());
    _notify();
  }

  Future<void> resume(ComicDownloadTask task) async {
    if (_activeId == task.id) await _activeTask?.future;
    task.status = ComicDownloadStatus.queued;
    task.error = null;
    await library.saveTask(task.id, task.toJson());
    _notify();
    _start();
  }

  Future<void> remove(ComicDownloadTask task) async {
    await pause(task);
    if (_activeId == task.id) await _activeTask?.future;
    // Only remove this task's explicitly stored files, never the selected root.
    for (var i = 0; i < task.pages.length; i++) {
      for (final path in [task.pathFor(i), '${task.pathFor(i)}.part']) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    }
    if (task.coverPath != null && await File(task.coverPath!).exists()) {
      await File(task.coverPath!).delete();
    }
    tasks.remove(task);
    await library.deleteTask(task.id);
    _notify();
  }

  Future<List<ComicPage>?> offlinePages(
    Comic comic,
    ComicChapter chapter,
  ) async {
    await ready;
    for (final task in tasks) {
      if (task.comic.key == comic.key &&
          task.chapter.id == chapter.id &&
          task.status == ComicDownloadStatus.complete) {
        final pages = <ComicPage>[];
        for (var i = 0; i < task.pages.length; i++) {
          if (!await File(task.pathFor(i)).exists()) {
            task.status = ComicDownloadStatus.failed;
            task.error = 'Downloaded file is missing.';
            await library.saveTask(task.id, task.toJson());
            _notify();
            return null;
          }
          pages.add(ComicPage(task.pages[i].url, localPath: task.pathFor(i)));
        }
        return pages;
      }
    }
    return null;
  }

  List<Comic> get completedComics => {
    for (final t in tasks.where(
      (t) => t.status == ComicDownloadStatus.complete,
    ))
      t.comic.key: Comic.fromJson({
        ...t.comic.toJson(),
        'extra': {
          ...t.comic.extra,
          if (t.coverPath != null) 'localCover': t.coverPath,
        },
      }),
  }.values.toList();
  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    super.dispose();
  }
}
