enum VideoLinkKind {
  navigation,
  category,
  actor,
  tag,
  studio,
  playlist,
  collection,
  video,
  other,
}

enum VideoSearchFilterKind { genre, actor, studio, series }

class VideoItem {
  const VideoItem({
    required this.id,
    required this.title,
    required this.pageUrl,
    this.cover = '',
    this.durationSeconds,
    this.releaseDate,
    this.actors = const [],
    this.tags = const [],
    this.makers = const [],
    this.labels = const [],
    this.series = const [],
    this.directors = const [],
    this.hasSubtitles = false,
    this.isUncensored = false,
  });

  final String id;
  final String title;
  final String pageUrl;
  final String cover;
  final int? durationSeconds;
  final String? releaseDate;
  final List<VideoLink> actors;
  final List<VideoLink> tags;
  final List<String> makers;
  final List<String> labels;
  final List<String> series;
  final List<String> directors;
  final bool hasSubtitles;
  final bool isUncensored;

  List<VideoLink> get cardTags =>
      tags.where((tag) => tag.cardMetadataRoute == null).toList();

  List<String> get cardMakers => _cardNames(makers, 'makers');
  List<String> get cardLabels => _cardNames(labels, 'labels');
  List<String> get cardSeries => _cardNames(series, 'series');
  List<String> get cardDirectors => _cardNames(directors, 'directors');

  // Older downloads store these directories together with genre tags.
  List<String> _cardNames(List<String> values, String route) =>
      [
            ...values,
            for (final tag in tags)
              if (tag.cardMetadataRoute == route) tag.label,
          ]
          .map((name) => name.trim())
          .where((name) => name.isNotEmpty)
          .toSet()
          .toList();

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'pageUrl': pageUrl,
    'cover': cover,
    'durationSeconds': durationSeconds,
    'releaseDate': releaseDate,
    'actors': actors.map((actor) => actor.toJson()).toList(),
    'tags': tags.map((tag) => tag.toJson()).toList(),
    'makers': makers,
    'labels': labels,
    'series': series,
    'directors': directors,
    'hasSubtitles': hasSubtitles,
    'isUncensored': isUncensored,
  };

  factory VideoItem.fromJson(Map<String, dynamic> json) => VideoItem(
    id: json['id'] as String,
    title: json['title'] as String,
    pageUrl: json['pageUrl'] as String,
    cover: json['cover'] as String? ?? '',
    durationSeconds: (json['durationSeconds'] as num?)?.toInt(),
    releaseDate: json['releaseDate'] as String?,
    actors: (json['actors'] as List? ?? const [])
        .map(
          (actor) =>
              VideoLink.fromJson(Map<String, dynamic>.from(actor as Map)),
        )
        .toList(),
    tags: (json['tags'] as List? ?? const [])
        .map((tag) => VideoLink.fromJson(Map<String, dynamic>.from(tag as Map)))
        .toList(),
    makers: (json['makers'] as List? ?? const []).whereType<String>().toList(),
    labels: (json['labels'] as List? ?? const []).whereType<String>().toList(),
    series: (json['series'] as List? ?? const []).whereType<String>().toList(),
    directors: (json['directors'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    hasSubtitles: json['hasSubtitles'] as bool? ?? false,
    isUncensored: json['isUncensored'] as bool? ?? false,
  );
}

class VideoLink {
  const VideoLink({
    required this.label,
    required this.url,
    this.cover = '',
    this.kind = VideoLinkKind.other,
    this.sourceKey,
    this.isAdded,
  });

  final String label;
  final String url;
  final String cover;
  final VideoLinkKind kind;
  final String? sourceKey;
  final bool? isAdded;

  String? get cardMetadataRoute {
    final segments = Uri.tryParse(url)?.pathSegments ?? const <String>[];
    for (var index = 0; index + 1 < segments.length; index++) {
      final route = switch (segments[index].toLowerCase()) {
        'maker' || 'makers' || 'studio' || 'studios' => 'makers',
        'label' || 'labels' => 'labels',
        'series' => 'series',
        'director' || 'directors' => 'directors',
        _ => null,
      };
      if (route != null) return route;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'label': label,
    'url': url,
    'cover': cover,
    'kind': kind.name,
    'sourceKey': sourceKey,
    'isAdded': isAdded,
  };

  factory VideoLink.fromJson(Map<String, dynamic> json) => VideoLink(
    label: json['label'] as String,
    url: json['url'] as String,
    cover: json['cover'] as String? ?? '',
    kind: VideoLinkKind.values.firstWhere(
      (kind) => kind.name == json['kind'],
      orElse: () => VideoLinkKind.other,
    ),
    sourceKey: json['sourceKey'] as String?,
    isAdded: json['isAdded'] as bool?,
  );
}

class VideoCatalogPage {
  const VideoCatalogPage({
    required this.title,
    required this.url,
    this.videos = const [],
    this.links = const [],
    this.navigation = const [],
    this.nextUrl,
    this.previousUrl,
    this.currentPage = 1,
    this.jumpMaxPage,
  });

  final String title;
  final String url;
  final List<VideoItem> videos;
  final List<VideoLink> links;
  final List<VideoLink> navigation;
  final String? nextUrl;
  final String? previousUrl;
  final int currentPage;
  final int? jumpMaxPage;

  String pageUrl(int page) {
    final uri = Uri.parse(nextUrl ?? previousUrl ?? url);
    return uri
        .replace(queryParameters: {...uri.queryParameters, 'page': '$page'})
        .toString();
  }
}

class VideoStream {
  const VideoStream({
    required this.label,
    required this.url,
    this.headers = const {},
    this.isHls = false,
  });

  final String label;
  final String url;
  final Map<String, String> headers;
  final bool isHls;
}

class VideoDetails {
  const VideoDetails({
    required this.video,
    this.description = '',
    this.metadata = const {},
    this.actors = const [],
    this.tags = const [],
    this.related = const [],
    this.streams = const [],
    this.sourceId,
    this.isFavorite,
  });

  final VideoItem video;
  final String description;
  final Map<String, String> metadata;
  final List<VideoLink> actors;
  final List<VideoLink> tags;
  final List<VideoItem> related;
  final List<VideoStream> streams;
  final String? sourceId;
  final bool? isFavorite;
}

class MissavException implements Exception {
  const MissavException(this.message, {this.sourceUrl, this.cause});

  final String message;
  final String? sourceUrl;
  final Object? cause;

  @override
  String toString() => message;
}

class MissavUnsupportedException extends MissavException {
  const MissavUnsupportedException({
    required this.capability,
    required String sourceUrl,
  }) : super(
         'MissAV capability is not supported: $capability',
         sourceUrl: sourceUrl,
       );

  final String capability;
}

class MissavAuthenticationException extends MissavException {
  const MissavAuthenticationException({
    String message = 'Sign in to your MissAV account.',
    String? sourceUrl,
  }) : super(message, sourceUrl: sourceUrl);
}

class MissavVerificationRequiredException extends MissavException {
  const MissavVerificationRequiredException({required String sourceUrl})
    : super('MissAV requires browser verification.', sourceUrl: sourceUrl);
}
