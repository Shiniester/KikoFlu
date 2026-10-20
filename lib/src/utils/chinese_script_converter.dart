import 'dart:math' as math;

import 'package:flutter/services.dart';

typedef _ChineseDictionary = ({Map<String, String> entries, int maxLength});

Future<_ChineseDictionary>? _simplifiedDictionary;
Future<_ChineseDictionary>? _traditionalDictionary;

Future<String> convertChineseScript(
  String text, {
  required bool toTraditional,
}) async {
  final dictionary = await (toTraditional
      ? _traditionalDictionary ??= _loadDictionary('ST')
      : _simplifiedDictionary ??= _loadDictionary('TS'));
  final result = StringBuffer();
  for (var offset = 0; offset < text.length;) {
    var length = math.min(dictionary.maxLength, text.length - offset);
    String? replacement;
    for (; length > 0; length--) {
      replacement = dictionary.entries[text.substring(offset, offset + length)];
      if (replacement != null) break;
    }
    result.write(replacement ?? text[offset]);
    offset += length > 0 ? length : 1;
  }
  return result.toString();
}

Future<_ChineseDictionary> _loadDictionary(String direction) async {
  final entries = <String, String>{};
  var maxLength = 1;
  for (final type in ['Phrases', 'Characters']) {
    final data = await rootBundle.loadString(
      'third_party/opencc/$direction$type.txt',
    );
    for (final line in data.split('\n')) {
      final fields = line.trim().split('\t');
      if (fields.length != 2) continue;
      // OpenCC lists the preferred conversion first when a character is ambiguous.
      entries.putIfAbsent(fields[0], () => fields[1].split(' ').first);
      maxLength = math.max(maxLength, fields[0].length);
    }
  }
  return (entries: entries, maxLength: maxLength);
}
