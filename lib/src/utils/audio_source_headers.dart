const japaneseAsmrRequestHeaders = <String, String>{
  'Referer': 'https://japaneseasmr.com/',
  'Origin': 'https://japaneseasmr.com',
  // just_audio's header proxy decompresses gzip but keeps Content-Encoding.
  'Accept-Encoding': 'identity',
};

Map<String, String> sourceAwareMediaHeaders(
  int? workId, {
  required Map<String, String> accountHeaders,
}) {
  return workId != null && workId < 0
      ? japaneseAsmrRequestHeaders
      : accountHeaders;
}
