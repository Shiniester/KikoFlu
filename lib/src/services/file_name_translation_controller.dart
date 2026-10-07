class FileNameTranslationController {
  FileNameTranslationController();

  final Map<String, String> translations = {};

  bool isBulkTranslating = false;
  String progress = '';
  int _generation = 0;

  void dispose() {
    _generation++;
    isBulkTranslating = false;
    progress = '';
  }

  String displayName(
    String originalName, {
    required bool showTranslation,
  }) {
    if (showTranslation && translations.containsKey(originalName)) {
      return translations[originalName]!;
    }

    return originalName;
  }

  int beginBulkTranslation(String initialProgress) {
    _generation++;
    isBulkTranslating = true;
    progress = initialProgress;
    return _generation;
  }

  bool updateBulkProgress(int generation, String nextProgress) {
    if (!_isCurrent(generation)) return false;
    progress = nextProgress;
    return true;
  }

  bool completeBulkTranslation(
    int generation,
    Map<String, String> nextTranslations,
  ) {
    if (!_isCurrent(generation)) return false;
    translations.addAll(nextTranslations);
    isBulkTranslating = false;
    progress = '';
    return true;
  }

  bool failBulkTranslation(int generation) {
    if (!_isCurrent(generation)) return false;
    isBulkTranslating = false;
    progress = '';
    return true;
  }

  bool _isCurrent(int generation) {
    return generation == _generation;
  }
}
