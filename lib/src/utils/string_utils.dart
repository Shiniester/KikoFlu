String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  } else if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  } else if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  } else {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

String formatDuration(Duration duration, {bool padHours = true}) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);

  if (hours > 0) {
    final hourText = padHours ? hours.toString().padLeft(2, '0') : '$hours';
    return '$hourText:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  } else {
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

String formatDurationSeconds(dynamic secondsValue, {bool padHours = true}) {
  final seconds = secondsValue is num ? secondsValue.toInt() : null;
  if (seconds == null || seconds <= 0) return '';

  return formatDuration(Duration(seconds: seconds), padHours: padHours);
}

String formatRJCode(int id) {
  String code = id.toString();
  if (code.length == 5) {
    code = '0$code';
  } else if (code.length == 7) {
    code = '0$code';
  }
  return 'RJ$code';
}

final _simplifiedChineseCharacters = RegExp(
  '[这们说语让听觉过还给远边轻欢爱亲够练经绪线绵软细钟错门关录档风纸书读优务专业丝动对从无贝见车东乐买产仅传伤兴军农决况冻净减凑刘则创剧办势华协卖卢卫县变叹吗呜员响哑唤啰简标题频视览译备缩缓发头]',
);
final _distinctiveTraditionalChineseCharacters = RegExp(
  '[這們說聽覺輕夠經關錄檔讀專絲對從產傳淨辦賣變嗎啞囉譯體聲戀發髮灣]',
);
final _kanaCharacters = RegExp('[\\u3040-\\u30ff\\uff66-\\uff9f]');
final _latinPhrase = RegExp(r'\b[a-zA-Z]+(?:\s+[a-zA-Z]+)+\b');

bool isClearlyChinese(String text) {
  // shortcut: unknown Chinese/Japanese shared characters still need translation; use language detection if broader coverage is needed.
  if (_kanaCharacters.hasMatch(text) || _latinPhrase.hasMatch(text)) return false;
  return _simplifiedChineseCharacters.hasMatch(text) ||
      _distinctiveTraditionalChineseCharacters.hasMatch(text);
}
