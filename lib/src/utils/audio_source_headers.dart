const japaneseAsmrRequestHeaders = <String, String>{
  'Referer': 'https://japaneseasmr.com/',
  'Origin': 'https://japaneseasmr.com',
};

Map<String, String> sourceAwareMediaHeaders(
  int? workId, {
  required Map<String, String> accountHeaders,
}) {
  return workId != null && workId < 0
      ? japaneseAsmrRequestHeaders
      : accountHeaders;
}
