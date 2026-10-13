import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../models/audio_track.dart';
import '../models/lyric/lyric_parser.dart';
import '../utils/local_file_url.dart';
import 'download_file_path_service.dart';
import 'subtitle_database.dart';
import 'subtitle_library_service.dart';

class GeneratedSubtitleStore {
  const GeneratedSubtitleStore();

  static const relativeDirectory =
      '${SubtitleLibraryService.savedFolderName}/生成字幕';

  static String audioIdentity(AudioTrack track) {
    final hash = track.hash;
    if (hash != null && hash.isNotEmpty && !hash.startsWith('local:')) {
      return '${track.workId ?? 0}:hash:$hash';
    }
    final localPath = track.sourcePath ?? LocalFileUrl.pathFromUrl(track.url);
    if (localPath != null) {
      return '${track.workId ?? 0}:file:${p.normalize(p.absolute(localPath))}';
    }
    return '${track.workId ?? 0}:track:${track.id}';
  }

  static bool isGeneratedRelativePath(String relativePath) =>
      relativePath.replaceAll('\\', '/').startsWith('$relativeDirectory/');

  Future<String?> find(AudioTrack track) async {
    await SubtitleLibraryService.ensureInitialized();
    final relativePath = await SubtitleDatabase.instance.getMeta(
      'generated_audio:${audioIdentity(track)}',
    );
    if (relativePath == null) return null;
    final root = await SubtitleLibraryService.getSubtitleLibraryDirectory();
    final file = File(p.joinAll([root.path, ...relativePath.split('/')]));
    if (!await file.exists()) return null;
    try {
      LyricParser.parse(await file.readAsString());
      return file.path;
    } on FormatException {
      return null;
    }
  }

  Future<String> save(
    AudioTrack track,
    String srt, {
    required CancelToken cancelToken,
  }) async {
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    LyricParser.parse(srt);
    final existing = await find(track);
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    if (existing != null) return existing;

    final root = await SubtitleLibraryService.getSubtitleLibraryDirectory();
    final directoryName = DateTime.now().microsecondsSinceEpoch.toString();
    final title = DownloadFilePathService.safePathSegment(
      '${SubtitleLibraryService.removeAudioExtension(track.title)}.srt',
    );
    final relativePath = '$relativeDirectory/$directoryName/$title';
    final destination = File(
      p.joinAll([root.path, ...relativePath.split('/')]),
    );
    await destination.parent.create(recursive: true);
    final temporary = File('${destination.path}.tmp');
    try {
      await temporary.writeAsString(srt, flush: true);
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      temporary.renameSync(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    await SubtitleDatabase.instance.setMeta(
      'generated_audio:${audioIdentity(track)}',
      relativePath,
    );
    await SubtitleLibraryService.refreshDirectoryCache(destination.parent.path);
    return destination.path;
  }
}
