import 'dart:convert';

enum ComicReadingMode {
  leftToRight,
  rightToLeft,
  vertical,
  continuous,
  spread,
  reverseSpread,
}

class ComicChapter {
  const ComicChapter(this.id, this.title);
  final String id;
  final String title;
  Map<String, dynamic> toJson() => {'id': id, 'title': title};
  factory ComicChapter.fromJson(Map<String, dynamic> json) =>
      ComicChapter('${json['id']}', '${json['title']}');
}

class Comic {
  const Comic({
    required this.source,
    required this.id,
    required this.title,
    this.cover = '',
    this.description = '',
    this.tags = const [],
    this.chapters = const [],
    this.rating,
    this.extra = const {},
  });
  final String source;
  final String id;
  final String title;
  final String cover;
  final String description;
  final List<String> tags;
  final List<ComicChapter> chapters;
  final String? rating;
  final Map<String, dynamic> extra;
  ComicPage get coverPage =>
      ComicPage(cover, localPath: extra['localCover'] as String?);
  String get key => jsonEncode([source, id]);
  Comic withChapters(List<ComicChapter> value) => Comic(
    source: source,
    id: id,
    title: title,
    cover: cover,
    description: description,
    tags: tags,
    chapters: value,
    rating: rating,
    extra: extra,
  );
  Map<String, dynamic> toJson() => {
    'source': source,
    'id': id,
    'title': title,
    'cover': cover,
    'description': description,
    'tags': tags,
    'chapters': chapters.map((c) => c.toJson()).toList(),
    'rating': rating,
    'extra': extra,
  };
  factory Comic.fromJson(Map<String, dynamic> j) => Comic(
    source: j['source'],
    id: j['id'],
    title: j['title'],
    cover: j['cover'] ?? '',
    description: j['description'] ?? '',
    tags: List<String>.from(j['tags'] ?? []),
    chapters: (j['chapters'] as List? ?? [])
        .map((c) => ComicChapter.fromJson(Map<String, dynamic>.from(c)))
        .toList(),
    rating: j['rating'],
    extra: Map<String, dynamic>.from(j['extra'] ?? {}),
  );
}

class ComicPage {
  const ComicPage(
    this.url, {
    this.headers = const {},
    this.scrambleId,
    this.localPath,
    this.resolveHtml = false,
  });
  final String url;
  final Map<String, String> headers;
  final int? scrambleId;
  final String? localPath;
  final bool resolveHtml;
  Map<String, dynamic> toJson() => {
    'url': url,
    'headers': headers,
    'scrambleId': scrambleId,
    'localPath': localPath,
    'resolveHtml': resolveHtml,
  };
  factory ComicPage.fromJson(Map<String, dynamic> j) => ComicPage(
    j['url'],
    headers: Map<String, String>.from(j['headers'] ?? {}),
    scrambleId: j['scrambleId'],
    localPath: j['localPath'],
    resolveHtml: j['resolveHtml'] ?? false,
  );
}

class ComicResult {
  const ComicResult(this.items, {this.next, this.totalPages});
  final List<Comic> items;
  final String? next;
  final int? totalPages;
}

class ComicComment {
  const ComicComment(this.author, this.text, {this.score});
  final String author;
  final String text;
  final String? score;
}

class ComicProgress {
  const ComicProgress(this.comic, this.chapterId, this.page, this.updatedAt);
  final Comic comic;
  final String chapterId;
  final int page;
  final DateTime updatedAt;
}

class ComicCategory {
  const ComicCategory(this.id, this.title);
  final String id;
  final String title;
}

class ComicSourceException implements Exception {
  const ComicSourceException(this.message, {this.loginRequired = false});
  final String message;
  final bool loginRequired;
  @override
  String toString() => message;
}
