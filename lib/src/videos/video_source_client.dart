import 'dart:async';

import 'package:dio/dio.dart';

import 'video_models.dart';

abstract interface class VideoSourceClient {
  String get sourceKey;
  String get homeUrl;
  String get defaultCatalogUrl;
  List<VideoSearchFilterKind> get searchFilterKinds;

  bool setLocale(String languageTag);
  Future<void> initialize();
  Future<VideoCatalogPage> browse(
    String url, {
    CancelToken? cancelToken,
    void Function(VideoCatalogPage page)? onParsed,
  });
  Future<VideoCatalogPage> search(String query);
  Future<VideoCatalogPage> searchFilterOptions(
    VideoSearchFilterKind kind, {
    String? pageUrl,
  });
  Future<List<VideoItem>> searchWithFilters(
    String query,
    List<VideoLink> filters, {
    bool Function()? isCurrent,
  });
  Future<VideoDetails> details(
    VideoItem item, {
    FutureOr<void> Function(VideoDetails)? onReady,
    bool includeAccountState = true,
  });
}

Future<List<VideoItem>> intersectVideoCatalogs({
  required Iterable<String> urls,
  required Future<VideoCatalogPage> Function(String) browse,
  required bool Function() isCurrent,
}) async {
  final candidates = <String, VideoItem>{};
  var firstSource = true;
  for (final source in urls.toSet()) {
    final first = Uri.parse(source).removeFragment();
    final parameters = Map<String, String>.of(first.queryParameters)
      ..remove('page');
    String? next = first.queryParameters.containsKey('page')
        ? parameters.isEmpty
              ? first.toString().split('?').first
              : first.replace(queryParameters: parameters).toString()
        : first.toString();
    final visited = <String>{};
    final matchingIds = <String>{};
    while (next != null && visited.add(next)) {
      if (!isCurrent()) return [];
      final page = await browse(next);
      if (!isCurrent()) return [];
      for (final video in page.videos) {
        if (firstSource) {
          candidates.putIfAbsent(video.id, () => video);
        } else if (candidates.containsKey(video.id)) {
          matchingIds.add(video.id);
        }
      }
      if (!firstSource && matchingIds.length == candidates.length) break;
      next = page.nextUrl;
    }
    if (!firstSource) {
      candidates.removeWhere((id, _) => !matchingIds.contains(id));
    }
    if (candidates.isEmpty) return [];
    firstSource = false;
  }
  return candidates.values.toList(growable: false);
}
