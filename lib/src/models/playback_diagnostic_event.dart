import 'package:flutter/foundation.dart';

enum PlaybackDiagnosticEventType {
  trackLoadStarted,
  trackReady,
  trackLoadFailed,
  unexpectedBuffering,
  playbackError,
  cacheError,
}

@immutable
class PlaybackDiagnosticEvent {
  const PlaybackDiagnosticEvent({
    required this.type,
    required this.timestamp,
    this.trackKey,
    this.workId,
    this.detail,
  });

  final PlaybackDiagnosticEventType type;
  final DateTime timestamp;
  final String? trackKey;
  final int? workId;

  /// A sanitized category such as an exception type. URLs and credentials are
  /// never stored in this field.
  final String? detail;

  Map<String, Object?> toJson() => {
    'type': type.name,
    'timestamp': timestamp.toUtc().toIso8601String(),
    if (trackKey != null) 'trackKey': trackKey,
    if (workId != null) 'workId': workId,
    if (detail != null) 'detail': detail,
  };
}
