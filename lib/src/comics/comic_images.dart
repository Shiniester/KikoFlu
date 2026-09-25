import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:html/parser.dart' as html;
import 'package:image/image.dart' as img;
import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'comic_models.dart';
import 'comic_http.dart';
import 'comic_source.dart';

typedef ComicImageLoader =
    Future<Uint8List> Function(ComicSource source, ComicPage page);

Future<Uint8List> readComicImage(ComicSource source, ComicPage page) =>
    loadComicImage(source.http, page);

final comicImageCache = CacheManager(
  Config('comic_images', maxNrOfCacheObjects: 500),
);

Future<Uint8List> loadComicImage(
  ComicHttp http,
  ComicPage page, {
  CancelToken? cancelToken,
}) async {
  if (page.localPath != null) return File(page.localPath!).readAsBytes();
  final cacheKey = '${http.source}:${page.scrambleId ?? ''}:${page.url}';
  final cached = await comicImageCache.getFileFromCache(cacheKey);
  if (cached != null && await cached.file.exists()) {
    return cached.file.readAsBytes();
  }
  var url = page.url;
  if (page.resolveHtml) {
    final doc = html.parse(await http.text(url, headers: page.headers));
    final image = doc.querySelector('#img')?.attributes['src'];
    if (image == null || image.isEmpty) {
      throw const ComicSourceException('Image link is unavailable.');
    }
    url = Uri.parse(url).resolve(image).toString();
  }
  final bytes = await http.bytes(
    url,
    headers: page.headers,
    cancelToken: cancelToken,
  );
  final decoded =
      page.scrambleId == null ||
          Uri.parse(url).path.toLowerCase().endsWith('.gif')
      ? bytes
      : await compute(decodeJmImage, (bytes, url, page.scrambleId!));
  // Reject login/error HTML returned with HTTP 200 before caching or downloading.
  final codec = await ui.instantiateImageCodec(decoded);
  codec.dispose();
  await comicImageCache.putFile(
    cacheKey,
    decoded,
    key: cacheKey,
    fileExtension: 'image',
  );
  return decoded;
}

// Image strip algorithm adapted from PicaComic (MIT, Copyright 2023 Nyne).
Uint8List decodeJmImage((Uint8List, String, int) input) {
  final (bytes, url, scrambleId) = input;
  final parts = Uri.parse(url).pathSegments;
  final chapter = int.parse(parts[parts.length - 2]);
  if (chapter < scrambleId) return bytes;
  final name = parts.last.split('.').first;
  var strips = 10;
  if (chapter >= 268850) {
    final hash = md5.convert(utf8.encode('$chapter$name')).toString();
    strips =
        (hash.codeUnitAt(hash.length - 1) % (chapter > 421926 ? 8 : 10)) * 2 +
        2;
  }
  final source = img.decodeImage(bytes);
  if (source == null) throw const FormatException('Invalid comic image');
  final output = img.Image(width: source.width, height: source.height);
  final height = source.height ~/ strips;
  final remainder = source.height % strips;
  for (var i = 0; i < strips; i++) {
    final dstY = height * i;
    final srcY = source.height - height * (i + 1) - remainder;
    final copyHeight = height + (i == 0 ? remainder : 0);
    img.compositeImage(
      output,
      source,
      dstY: dstY + (i == 0 ? 0 : remainder),
      srcY: srcY,
      srcH: copyHeight,
      srcW: source.width,
      dstH: copyHeight,
      dstW: source.width,
    );
  }
  return Uint8List.fromList(img.encodePng(output));
}
