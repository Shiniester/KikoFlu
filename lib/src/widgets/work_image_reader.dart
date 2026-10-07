import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../comics/ui/comic_reader_screen.dart';
import '../services/cache_service.dart';
import '../services/storage_service.dart';
import '../utils/local_file_url.dart';

class WorkImageReader extends StatelessWidget {
  const WorkImageReader({
    super.key,
    required this.title,
    required this.images,
    this.initialIndex = 0,
  });

  final String title;
  final List<Map<String, String>> images;
  final int initialIndex;

  @override
  Widget build(BuildContext context) => ComicReaderScreen.images(
    title: title,
    imageTitles: images.map((image) => image['title'] ?? '').toList(),
    initialPage: initialIndex,
    loadImage: (index) => _loadImage(images[index]),
  );

  Future<Uint8List> _loadImage(Map<String, String> image) async {
    final imageUrl = image['url'] ?? '';
    final localPath = LocalFileUrl.pathFromUrl(imageUrl);
    if (localPath != null) return File(localPath).readAsBytes();

    final lease = CacheService.imageCacheManager.acquireFile(
      imageUrl,
      key:
          image['cacheKey'] ??
          CacheService.imageCacheKey(imageUrl: imageUrl, hash: image['hash']),
      headers: StorageService.serverCookieHeaders,
    );
    try {
      return await (await lease.file).readAsBytes();
    } finally {
      await lease.release();
    }
  }
}
