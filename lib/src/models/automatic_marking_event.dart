import 'audio_track.dart';

enum AutomaticMarkingEventType {
  replace,
  restore,
  added,
  selected,
  started,
  completed,
  removed,
}

class AutomaticMarkingEvent {
  const AutomaticMarkingEvent(
    this.type, {
    required this.queueId,
    required this.queue,
    this.tracks = const [],
    this.track,
  });

  final AutomaticMarkingEventType type;
  final String queueId;
  final List<AudioTrack> queue;
  final List<AudioTrack> tracks;
  final AudioTrack? track;
}
