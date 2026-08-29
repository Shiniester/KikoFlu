import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:path/path.dart' as p;

import 'subtitle_library_rules.dart';

/// Parameters for an archive extraction job.
///
/// The request intentionally contains only isolate-safe values so the complete
/// ZIP walk and decompression can run away from the UI isolate.
class StreamingZipExtractionRequest {
  const StreamingZipExtractionRequest({
    required this.sourcePath,
    required this.targetPath,
    required this.archiveName,
    this.maxDepth = 10,
    this.maxNestedArchiveSize = 1024 * 1024 * 1024,
    this.maxEntrySize = 500 * 1024 * 1024,
    this.maxPathLength = SubtitleLibraryRules.maxPathLength,
  });

  final String sourcePath;
  final String targetPath;
  final String archiveName;
  final int maxDepth;
  final int maxNestedArchiveSize;
  final int maxEntrySize;
  final int maxPathLength;
}

class StreamingZipExtractionResult {
  const StreamingZipExtractionResult({
    this.extractedCount = 0,
    this.errorCount = 0,
    this.skippedCount = 0,
    this.nestedArchiveCount = 0,
    this.sizeErrorCount = 0,
    this.depthErrorCount = 0,
    this.decodeErrorCount = 0,
    this.rootDecodeError,
  });

  final int extractedCount;
  final int errorCount;
  final int skippedCount;
  final int nestedArchiveCount;
  final int sizeErrorCount;
  final int depthErrorCount;
  final int decodeErrorCount;
  final String? rootDecodeError;

  bool get decodedRootArchive => rootDecodeError == null;
}

/// Extracts ZIP entries one at a time from an [InputFileStream].
///
/// This avoids loading the complete archive with `File.readAsBytes` and writes
/// nested archives to temporary files before decoding them. The async entry
/// point executes the entire job in a background isolate.
class StreamingZipExtractor {
  const StreamingZipExtractor._();

  static Future<StreamingZipExtractionResult> extract(
    StreamingZipExtractionRequest request,
  ) {
    return Isolate.run(() => extractSynchronously(request));
  }

  /// Synchronous implementation exposed for deterministic unit benchmarks.
  static StreamingZipExtractionResult extractSynchronously(
    StreamingZipExtractionRequest request,
  ) {
    final state = _ExtractionState(request);
    final nestedTempDirectory = Directory(
      p.join(request.targetPath, '.nested_archives'),
    );

    InputFileStream? input;
    try {
      input = InputFileStream(request.sourcePath);
      final archive = ZipDecoder().decodeBuffer(input, verify: false);

      var relativePath = '';
      if (SubtitleLibraryRules.matchesWorkFolderName(request.archiveName) &&
          SubtitleLibraryRules.shouldCreateNewFolderForArchive(
            archive,
            request.archiveName,
          )) {
        relativePath = request.archiveName;
      }

      _extractArchive(
        archive,
        request.targetPath,
        relativePath,
        nestedTempDirectory,
        state,
        depth: 0,
      );
    } catch (error) {
      state.rootDecodeError ??= error.toString();
      state.errorCount++;
      state.decodeErrorCount++;
    } finally {
      input?.closeSync();
      if (nestedTempDirectory.existsSync()) {
        nestedTempDirectory.deleteSync(recursive: true);
      }
    }

    return state.toResult();
  }

  static void _extractArchive(
    Archive archive,
    String targetBasePath,
    String relativePath,
    Directory nestedTempDirectory,
    _ExtractionState state, {
    required int depth,
  }) {
    if (depth > state.request.maxDepth) {
      state.errorCount++;
      state.depthErrorCount++;
      return;
    }

    for (final file in archive.files) {
      if (!file.isFile || file.isSymbolicLink) {
        continue;
      }

      final decodedName = _decodeArchiveName(file.name);
      final fileName = decodedName.split('/').last;
      if (fileName.isEmpty || file.size <= 0) {
        state.skippedCount++;
        continue;
      }

      final extension = p.extension(fileName).toLowerCase();
      if (extension == '.zip') {
        _extractNestedArchive(
          file,
          decodedName,
          targetBasePath,
          relativePath,
          nestedTempDirectory,
          state,
          depth: depth,
        );
        continue;
      }

      if (!_isSubtitleFile(fileName)) {
        state.skippedCount++;
        continue;
      }

      if (file.size > state.request.maxEntrySize) {
        state.sizeErrorCount++;
        state.skippedCount++;
        continue;
      }

      final fullRelativePath = relativePath.isEmpty
          ? decodedName
          : '$relativePath/$decodedName';
      var targetFilePath = _safeJoin(targetBasePath, fullRelativePath);
      if (targetFilePath == null) {
        state.skippedCount++;
        continue;
      }

      if (targetFilePath.length > state.request.maxPathLength) {
        targetFilePath = _shortenPath(
          targetBasePath,
          targetFilePath,
          fileName,
          state.request.maxPathLength,
        );
        if (targetFilePath == null) {
          state.skippedCount++;
          continue;
        }
      }

      final targetFile = File(targetFilePath);
      try {
        targetFile.parent.createSync(recursive: true);
        _writeArchiveEntry(file, targetFile.path);
        state.extractedCount++;
      } catch (_) {
        state.errorCount++;
        if (targetFile.existsSync()) {
          targetFile.deleteSync();
        }
      }
    }
  }

  static void _extractNestedArchive(
    ArchiveFile file,
    String decodedName,
    String targetBasePath,
    String relativePath,
    Directory nestedTempDirectory,
    _ExtractionState state, {
    required int depth,
  }) {
    state.nestedArchiveCount++;

    if (depth + 1 > state.request.maxDepth) {
      state.errorCount++;
      state.depthErrorCount++;
      return;
    }
    if (file.size > state.request.maxNestedArchiveSize) {
      state.errorCount++;
      state.sizeErrorCount++;
      return;
    }

    nestedTempDirectory.createSync(recursive: true);
    final nestedPath = p.join(
      nestedTempDirectory.path,
      '${depth + 1}_${state.nextNestedArchiveId++}.zip',
    );

    InputFileStream? nestedInput;
    try {
      _writeArchiveEntry(file, nestedPath);
      nestedInput = InputFileStream(nestedPath);
      final nestedArchive = ZipDecoder().decodeBuffer(
        nestedInput,
        verify: false,
      );

      final zipNameWithoutExtension = decodedName.replaceAll(
        RegExp(r'\.zip$', caseSensitive: false),
        '',
      );
      final shouldCreateFolder =
          SubtitleLibraryRules.shouldCreateNewFolderForArchive(
            nestedArchive,
            zipNameWithoutExtension,
          );
      final nestedRelativePath = shouldCreateFolder
          ? (relativePath.isEmpty
                ? zipNameWithoutExtension
                : '$relativePath/$zipNameWithoutExtension')
          : relativePath;

      _extractArchive(
        nestedArchive,
        targetBasePath,
        nestedRelativePath,
        nestedTempDirectory,
        state,
        depth: depth + 1,
      );
    } catch (_) {
      state.errorCount++;
      state.decodeErrorCount++;
    } finally {
      nestedInput?.closeSync();
      final nestedFile = File(nestedPath);
      if (nestedFile.existsSync()) {
        nestedFile.deleteSync();
      }
    }
  }

  static void _writeArchiveEntry(ArchiveFile file, String targetPath) {
    final output = OutputFileStream(targetPath);
    try {
      file.writeContent(output);
    } finally {
      output.closeSync();
    }
  }

  static String _decodeArchiveName(String name) {
    try {
      return gbk_bytes.decode(latin1.encode(name));
    } catch (_) {
      return name;
    }
  }

  static bool _isSubtitleFile(String fileName) {
    const extensions = {
      '.vtt',
      '.srt',
      '.lrc',
      '.txt',
      '.ass',
      '.ssa',
      '.sub',
      '.idx',
      '.sbv',
      '.dfxp',
      '.ttml',
    };
    return extensions.contains(p.extension(fileName).toLowerCase());
  }

  static String? _safeJoin(String rootPath, String relativePath) {
    final safeSegments = relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((segment) => segment.trim().isNotEmpty)
        .where((segment) {
          final trimmed = segment.trim();
          return trimmed != '.' && trimmed != '..';
        })
        .map(
          (segment) => segment.replaceFirstMapped(
            RegExp(r'^([a-zA-Z]):'),
            (match) => '${match.group(1)}_',
          ),
        )
        .toList(growable: false);

    if (safeSegments.isEmpty) {
      return null;
    }

    final normalizedRoot = p.normalize(p.absolute(rootPath));
    final candidate = p.normalize(p.joinAll([normalizedRoot, ...safeSegments]));
    final relative = p.relative(candidate, from: normalizedRoot);
    if (relative == '..' || relative.startsWith('..${p.separator}')) {
      return null;
    }
    return candidate;
  }

  static String? _shortenPath(
    String rootPath,
    String fullPath,
    String fileName,
    int maxPathLength,
  ) {
    final normalizedRoot = p.normalize(p.absolute(rootPath));
    final extension = p.extension(fileName);
    final baseName = p.basenameWithoutExtension(fileName);
    final hash = _stableHash(fullPath).toRadixString(16).padLeft(8, '0');
    final availableNameLength =
        maxPathLength -
        normalizedRoot.length -
        hash.length -
        extension.length -
        8;
    if (availableNameLength <= 0) {
      return null;
    }

    final shortenedName = baseName.length > availableNameLength
        ? baseName.substring(0, availableNameLength)
        : baseName;
    final candidate = p.join(
      normalizedRoot,
      '.long_paths',
      hash,
      '$shortenedName$extension',
    );
    return candidate.length <= maxPathLength ? candidate : null;
  }

  static int _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }
}

class _ExtractionState {
  _ExtractionState(this.request);

  final StreamingZipExtractionRequest request;
  int extractedCount = 0;
  int errorCount = 0;
  int skippedCount = 0;
  int nestedArchiveCount = 0;
  int sizeErrorCount = 0;
  int depthErrorCount = 0;
  int decodeErrorCount = 0;
  int nextNestedArchiveId = 0;
  String? rootDecodeError;

  StreamingZipExtractionResult toResult() {
    return StreamingZipExtractionResult(
      extractedCount: extractedCount,
      errorCount: errorCount,
      skippedCount: skippedCount,
      nestedArchiveCount: nestedArchiveCount,
      sizeErrorCount: sizeErrorCount,
      depthErrorCount: depthErrorCount,
      decodeErrorCount: decodeErrorCount,
      rootDecodeError: rootDecodeError,
    );
  }
}
