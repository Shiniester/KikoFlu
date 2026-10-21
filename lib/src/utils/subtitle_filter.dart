import '../models/work.dart';

enum SubtitleFilterMode {
  all(0),
  withSubtitles(1);

  const SubtitleFilterMode(this.value);

  final int value;

  static SubtitleFilterMode fromValue(int value) {
    return SubtitleFilterMode.values.firstWhere(
      (mode) => mode.value == value,
      orElse: () => SubtitleFilterMode.all,
    );
  }

  SubtitleFilterMode get next {
    return switch (this) {
      SubtitleFilterMode.all => SubtitleFilterMode.withSubtitles,
      SubtitleFilterMode.withSubtitles => SubtitleFilterMode.all,
    };
  }

  bool get isActive => this != SubtitleFilterMode.all;
}

List<Work> filterWorksBySubtitleMode(List<Work> works, int subtitleFilter) {
  final mode = SubtitleFilterMode.fromValue(subtitleFilter);
  return works.where((work) {
    return !mode.isActive || work.hasSubtitle == true;
  }).toList();
}
