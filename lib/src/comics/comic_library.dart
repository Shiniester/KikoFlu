import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'comic_models.dart';

class ComicLibrary extends ChangeNotifier {
  ComicLibrary({this.databaseOpener});
  final Future<Database> Function()? databaseOpener;
  Future<Database>? _database;
  bool _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<Database> get database =>
      _database ??= databaseOpener?.call() ?? _openDatabase();
  Future<Database> _openDatabase() async {
    final dir = await getApplicationSupportDirectory();
    await Directory(dir.path).create(recursive: true);
    return openDatabase(
      p.join(dir.path, 'comics.db'),
      version: 1,
      onCreate: createSchema,
    );
  }

  static Future<void> createSchema(Database db, int version) async {
    await db.execute(
      'CREATE TABLE favorites (id TEXT PRIMARY KEY, comic TEXT NOT NULL, updated INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE history (id TEXT PRIMARY KEY, comic TEXT NOT NULL, chapter TEXT NOT NULL, page INTEGER NOT NULL, updated INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE downloads (id TEXT PRIMARY KEY, task TEXT NOT NULL)',
    );
  }

  Future<List<Comic>> favorites() async => (await (await database).query(
    'favorites',
    orderBy: 'updated DESC',
  )).map((r) => Comic.fromJson(jsonDecode(r['comic'] as String))).toList();
  Future<bool> isFavorite(Comic comic) async => (await (await database).query(
    'favorites',
    where: 'id = ?',
    whereArgs: [comic.key],
  )).isNotEmpty;
  Future<void> favorite(Comic comic, bool value) async {
    final db = await database;
    if (value) {
      await db.insert('favorites', {
        'id': comic.key,
        'comic': jsonEncode(comic.toJson()),
        'updated': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await db.delete('favorites', where: 'id = ?', whereArgs: [comic.key]);
    }
    _notify();
  }

  Future<void> saveProgress(Comic comic, String chapter, int page) async {
    await (await database).insert('history', {
      'id': comic.key,
      'comic': jsonEncode(comic.toJson()),
      'chapter': chapter,
      'page': page,
      'updated': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _notify();
  }

  ComicProgress _progress(Map<String, Object?> r) => ComicProgress(
    Comic.fromJson(jsonDecode(r['comic'] as String)),
    r['chapter'] as String,
    r['page'] as int,
    DateTime.fromMillisecondsSinceEpoch(r['updated'] as int),
  );
  Future<ComicProgress?> progress(Comic comic) async {
    final rows = await (await database).query(
      'history',
      where: 'id = ?',
      whereArgs: [comic.key],
    );
    return rows.isEmpty ? null : _progress(rows.first);
  }

  Future<List<ComicProgress>> history() async => (await (await database).query(
    'history',
    orderBy: 'updated DESC',
  )).map(_progress).toList();
  Future<void> removeHistory(Comic comic) async {
    await (await database).delete(
      'history',
      where: 'id = ?',
      whereArgs: [comic.key],
    );
    _notify();
  }

  Future<List<Map<String, dynamic>>> loadTasks() async =>
      (await (await database).query('downloads'))
          .map(
            (r) => Map<String, dynamic>.from(jsonDecode(r['task'] as String)),
          )
          .toList();
  Future<void> saveTask(String id, Map<String, dynamic> task) async {
    await (await database).insert('downloads', {
      'id': id,
      'task': jsonEncode(task),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteTask(String id) async {
    await (await database).delete(
      'downloads',
      where: 'id = ?',
      whereArgs: [id],
    );
    _notify();
  }
}
