enum PlayerSubtitleLanguage {
  simplifiedChinese,
  traditionalChinese,
  other,
  none,
  unknown,
}

enum AudioFormat {
  wav('WAV', 'wav'),
  flac('FLAC', 'flac'),
  mp3('MP3', 'mp3'),
  opus('Opus', 'opus'),
  m4a('M4A', 'm4a'),
  aac('AAC', 'aac'),
  other('Other', 'other');

  const AudioFormat(this.displayName, this.extension);

  final String displayName;
  final String extension;
}

typedef PlayerAudioFormat = AudioFormat;

enum PlayerBinaryTrait { present, absent, unknown }

class AudioFormatPreference {
  const AudioFormatPreference({
    this.priority = const [
      AudioFormat.wav,
      AudioFormat.flac,
      AudioFormat.mp3,
      AudioFormat.opus,
      AudioFormat.m4a,
      AudioFormat.aac,
      AudioFormat.other,
    ],
    this.subtitleLanguage = PlayerSubtitleLanguage.simplifiedChinese,
    this.se = PlayerBinaryTrait.present,
    this.ejaculation = PlayerBinaryTrait.present,
    this.includeUnknown = true,
  });

  final List<AudioFormat> priority;
  final PlayerSubtitleLanguage subtitleLanguage;
  final PlayerBinaryTrait se;
  final PlayerBinaryTrait ejaculation;
  final bool includeUnknown;

  AudioFormatPreference copyWith({
    List<AudioFormat>? priority,
    PlayerSubtitleLanguage? subtitleLanguage,
    PlayerBinaryTrait? se,
    PlayerBinaryTrait? ejaculation,
    bool? includeUnknown,
  }) => AudioFormatPreference(
    priority: priority ?? this.priority,
    subtitleLanguage: subtitleLanguage ?? this.subtitleLanguage,
    se: se ?? this.se,
    ejaculation: ejaculation ?? this.ejaculation,
    includeUnknown: includeUnknown ?? this.includeUnknown,
  );
}
