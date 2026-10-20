import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/utils/audio_source_headers.dart';

void main() {
  test('Japanese media headers do not include account cookies or tokens', () {
    final headers = sourceAwareMediaHeaders(
      -1726738,
      accountHeaders: const {
        'Cookie': 'account-cookie',
        'Authorization': 'Bearer account-token',
      },
    );

    expect(headers, japaneseAsmrRequestHeaders);
    expect(
      headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('cookie')),
    );
    expect(
      headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('authorization')),
    );
  });

  test('ASMR media keeps the account request headers', () {
    const accountHeaders = {'Cookie': 'account-cookie'};

    expect(
      sourceAwareMediaHeaders(123, accountHeaders: accountHeaders),
      accountHeaders,
    );
  });
}
