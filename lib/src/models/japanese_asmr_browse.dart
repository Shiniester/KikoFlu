enum JapaneseAsmrSortOption { date, title, comments, popular }

enum JapaneseAsmrPeriod {
  recent('recent'),
  week('week'),
  twoWeeks('2_weeks'),
  month('month'),
  sixMonths('6_months'),
  year('year'),
  allTime(null),
  archiveYear(null),
  archiveMonth(null);

  const JapaneseAsmrPeriod(this.date);

  final String? date;

  bool get isArchive => this == archiveYear || this == archiveMonth;
}
