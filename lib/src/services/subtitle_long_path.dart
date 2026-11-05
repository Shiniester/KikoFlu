import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'subtitle_library_rules.dart';

class SubtitleLongPathInfo {
  const SubtitleLongPathInfo(this.originalPath, this.storedName);

  final String originalPath;
  final String storedName;
}

class SubtitleLongPath {
  static const markerName = '.i';
  static final _directoryPattern = RegExp(r'^long_[0-9a-f]{8}(?:_\d+)?$');

  static SubtitleLongPathInfo? readDirectorySync(
    String directoryPath, {
    bool allowRenamed = false,
  }) {
    if (!allowRenamed &&
        !_directoryPattern.hasMatch(p.basename(directoryPath))) {
      return null;
    }
    final marker = File(p.join(directoryPath, markerName));
    if (!marker.existsSync()) return null;
    try {
      final data = jsonDecode(marker.readAsStringSync());
      if (data is! Map) return null;
      final originalPath = data['path'];
      final storedName = data['file'];
      if (originalPath is! String || storedName is! String) return null;
      final parts = originalPath.split('/');
      if (p.isAbsolute(originalPath) ||
          parts.any(
            (part) =>
                part.isEmpty ||
                part == '.' ||
                part == '..' ||
                (Platform.isWindows && part.contains('\\')),
          ) ||
          storedName.isEmpty ||
          storedName == '.' ||
          storedName == '..' ||
          storedName.contains('/') ||
          (Platform.isWindows && storedName.contains('\\'))) {
        return null;
      }
      return SubtitleLongPathInfo(originalPath, storedName);
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  static SubtitleLongPathInfo? readFileSync(
    String path, {
    bool allowRenamed = false,
  }) {
    final info = readDirectorySync(p.dirname(path), allowRenamed: allowRenamed);
    return info?.storedName == p.basename(path) ? info : null;
  }

  static Future<Map<String, String>> existingPaths(String rootPath) async {
    final paths = <String, String>{};
    final root = Directory(rootPath);
    if (!await root.exists()) return paths;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory ||
          !_directoryPattern.hasMatch(p.basename(entity.path))) {
        continue;
      }
      final info = readDirectorySync(entity.path);
      if (info != null) {
        paths[info.originalPath] = p.join(entity.path, info.storedName);
      }
    }
    return paths;
  }

  static String? resolve(
    String rootPath,
    String originalPath, {
    int maxPathLength = SubtitleLibraryRules.maxPathLength,
  }) {
    final hash = SubtitleLibraryRules.stablePathHash(
      originalPath,
    ).toRadixString(16).padLeft(8, '0');
    final fileName = p.posix.basename(originalPath);
    final extension = p.extension(fileName);
    final baseName = p.basenameWithoutExtension(fileName);

    for (var suffix = 0; ; suffix++) {
      final directory = p.join(
        rootPath,
        'long_$hash${suffix == 0 ? '' : '_$suffix'}',
      );
      final available = maxPathLength - directory.length - 1 - extension.length;
      if (available <= 0) return null;

      final type = FileSystemEntity.typeSync(directory, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        if (type == FileSystemEntityType.directory) {
          final info = readDirectorySync(directory);
          if (info?.originalPath == originalPath) {
            return p.join(directory, info!.storedName);
          }
        }
        continue;
      }

      var nameLength = baseName.length > available
          ? available
          : baseName.length;
      if (nameLength < baseName.length &&
          nameLength > 0 &&
          baseName.codeUnitAt(nameLength - 1) >= 0xd800 &&
          baseName.codeUnitAt(nameLength - 1) <= 0xdbff &&
          baseName.codeUnitAt(nameLength) >= 0xdc00 &&
          baseName.codeUnitAt(nameLength) <= 0xdfff) {
        nameLength--;
      }
      final shortenedName = nameLength == 0
          ? '_'
          : baseName.substring(0, nameLength);
      final storedName = '$shortenedName$extension';
      Directory(directory).createSync(recursive: true);
      File(p.join(directory, markerName)).writeAsStringSync(
        jsonEncode({'path': originalPath, 'file': storedName}),
      );
      return p.join(directory, storedName);
    }
  }
}
