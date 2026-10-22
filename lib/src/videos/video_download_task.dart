import 'video_models.dart';

enum VideoDownloadStatus { queued, downloading, paused, failed, completed }

class VideoDownloadTask {
  const VideoDownloadTask({
    required this.id,
    required this.video,
    required this.quality,
    required this.isHls,
    required this.status,
    this.progress = 0,
    this.localPath,
    this.error,
  });

  final String id;
  final VideoItem video;
  final String quality;
  final bool isHls;
  final VideoDownloadStatus status;
  final double progress;
  final String? localPath;
  final String? error;

  VideoDownloadTask copyWith({
    VideoDownloadStatus? status,
    double? progress,
    String? localPath,
    String? error,
    bool clearError = false,
  }) => VideoDownloadTask(
    id: id,
    video: video,
    quality: quality,
    isHls: isHls,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    localPath: localPath ?? this.localPath,
    error: clearError ? null : error ?? this.error,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'video': {
      ...video.toJson(),
      'pageUrl': _withoutCredentials(video.pageUrl),
      'cover': _withoutCredentials(video.cover),
    },
    'quality': quality,
    'isHls': isHls,
    'status': status.name,
    'progress': progress,
    'error': error,
  };

  factory VideoDownloadTask.fromJson(Map<String, dynamic> json) {
    final video = VideoItem.fromJson(
      Map<String, dynamic>.from(json['video'] as Map),
    );
    return VideoDownloadTask(
      id: json['id'] as String? ?? video.id,
      video: video,
      quality: json['quality'] as String,
      isHls: json['isHls'] as bool? ?? false,
      status: VideoDownloadStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => VideoDownloadStatus.paused,
      ),
      progress: ((json['progress'] as num?)?.toDouble() ?? 0)
          .clamp(0, 1)
          .toDouble(),
      error: json['error'] as String?,
    );
  }
}

String _withoutCredentials(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) return value;
  final query = <String, List<String>>{};
  if (uri.hasQuery) {
    for (final entry in uri.queryParametersAll.entries) {
      if (!_isCredentialQueryName(entry.key)) {
        query[entry.key] = entry.value;
      }
    }
  }
  return uri
      .replace(
        userInfo: uri.userInfo.isEmpty ? null : '',
        queryParameters: uri.hasQuery ? query : null,
        fragment: uri.hasFragment ? '' : null,
      )
      .toString();
}

bool _isCredentialQueryName(String name) {
  final normalized = name.toLowerCase().replaceAll('-', '_');
  return normalized.contains('token') ||
      normalized.contains('auth') ||
      normalized.contains('cookie') ||
      normalized.contains('key') ||
      normalized.contains('password') ||
      normalized.contains('session') ||
      normalized.contains('signature') ||
      normalized == 'sig' ||
      normalized.contains('credential') ||
      normalized.contains('secret') ||
      normalized == 'policy';
}
