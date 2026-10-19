import 'dart:ui';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/translation_service.dart';
import 'package:kikoeru_flutter/src/services/generated_subtitle_translation_service.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final previousHttpOverrides = HttpOverrides.current;
  final network = _FakeHttpOverrides();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'locale_language': 'en',
      TranslationLanguagePreferencesNotifier.keyTargetLanguage: 'en',
      'translation_source': 'youdao',
    });
    network.reset();
    HttpOverrides.global = network;
  });

  tearDown(() {
    HttpOverrides.global = previousHttpOverrides;
  });

  test(
    'generated translation freezes its target across chunks when preferences change',
    () async {
      final prefs = await SharedPreferences.getInstance();
      network.responseFor = (uri) => uri.host == 'dict.youdao.com'
          ? _FakeReply.json(200, {
              'translateResult': [
                [
                  {'tgt': 'Hello'},
                ],
              ],
            })
          : null;
      final directory = await Directory.systemTemp.createTemp(
        'generated-frozen-target-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final original = await File('${directory.path}/voice.srt').writeAsString(
        '1\n00:00:01,000 --> 00:00:02,000\n${'あ' * 1000}\n\n'
        '2\n00:00:02,000 --> 00:00:03,000\n${'い' * 1000}\n\n',
      );
      final result = await GeneratedSubtitleTranslationService().translate(
        original.path,
        saveTranslation: false,
        targetLocale: const Locale('en'),
        cancelToken: CancelToken(),
        onProgress: (progress) {
          if (progress < 1) {
            prefs.setString(
              TranslationLanguagePreferencesNotifier.keyTargetLanguage,
              'ja',
            );
          }
        },
      );
      expect(network.requests, hasLength(2));
      expect(network.requests.map((uri) => uri.queryParameters['to']), [
        'en',
        'en',
      ]);
      expect(result.targetLocale, const Locale('en'));
      expect(
        prefs.getString(
          TranslationLanguagePreferencesNotifier.keyTargetLanguage,
        ),
        'ja',
      );
    },
  );

  for (final invalid in ['Hello', 'Hello\n\nStory']) {
    test(
      'generated translation falls back before caching invalid cues: $invalid',
      () async {
        network.responseFor = (uri) {
          if (uri.host == 'dict.youdao.com') {
            return _FakeReply.json(200, {
              'translateResult': [
                [
                  {'tgt': invalid},
                ],
              ],
            });
          }
          if (uri.host == 'api.cognitive.microsofttranslator.com') {
            return _FakeReply.json(200, [
              {
                'translations': [
                  {'text': 'Hello\nListen\nStory'},
                ],
              },
            ]);
          }
          return null;
        };
        final directory = await Directory.systemTemp.createTemp(
          'translation-line-fallback-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final original = await File('${directory.path}/voice.srt')
            .writeAsString(
              '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n\n'
              '2\n00:00:02,000 --> 00:00:03,000\n聴いて\n\n'
              '3\n00:00:03,000 --> 00:00:04,000\n物語\n\n',
            );
        final service = GeneratedSubtitleTranslationService();
        Future<GeneratedSubtitleTranslation> translate() => service.translate(
          original.path,
          saveTranslation: false,
          targetLocale: const Locale('en'),
          cancelToken: CancelToken(),
          onProgress: (_) {},
        );
        expect((await translate()).translated.map((line) => line.text), [
          'Hello',
          'Listen',
          'Story',
        ]);
        expect(network.requests.map((uri) => uri.host), [
          'dict.youdao.com',
          'api.cognitive.microsofttranslator.com',
        ]);
        final requestCount = network.requests.length;
        expect((await translate()).translated.map((line) => line.text), [
          'Hello',
          'Listen',
          'Story',
        ]);
        expect(network.requests, hasLength(requestCount));
      },
    );
  }

  test(
    'generated translation retry recovers and evicts an invalid old cache',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'translation-line-retry-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final original = await File('${directory.path}/voice.srt').writeAsString(
        '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n\n'
        '2\n00:00:02,000 --> 00:00:03,000\n物語\n\n',
      );
      var recovered = false;
      network.responseFor = (uri) => uri.host == 'dict.youdao.com'
          ? _FakeReply.json(200, {
              'translateResult': [
                [
                  {'tgt': recovered ? 'Hello\nStory' : 'Hello'},
                ],
              ],
            })
          : null;
      final service = GeneratedSubtitleTranslationService();
      Future<GeneratedSubtitleTranslation> translate() => service.translate(
        original.path,
        saveTranslation: false,
        targetLocale: const Locale('en'),
        cancelToken: CancelToken(),
        onProgress: (_) {},
      );
      await expectLater(translate(), throwsStateError);
      const source = 'こんにちは\n物語';
      final key = 'translation_cache_ja_en_${source.hashCode}';
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(key), isNull);
      await prefs.setString(
        key,
        jsonEncode({
          'translation': 'Hello',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      recovered = true;
      final requestsBeforeRetry = network.requests.length;
      expect((await translate()).translated.map((line) => line.text), [
        'Hello',
        'Story',
      ]);
      expect(network.requests.length, requestsBeforeRetry + 1);
      expect(jsonDecode(prefs.getString(key)!)['translation'], 'Hello\nStory');
    },
  );

  test(
    'strict translation reports an offline failure for whole text and chunks',
    () async {
      final service = TranslationService();
      await expectLater(
        service.translate('こんにちは', sourceLang: 'ja', throwOnFailure: true),
        throwsStateError,
      );
      await expectLater(
        service.translateLongText(
          'こんにちは',
          sourceLang: 'ja',
          throwOnFailure: true,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'generated subtitles reuse the selected source, fallback, and global target',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        TranslationLanguagePreferencesNotifier.keyTargetLanguage,
        'zh_hant',
      );
      network.responseFor = (uri) =>
          uri.host == 'api.cognitive.microsofttranslator.com'
          ? _FakeReply.json(200, [
              {
                'translations': [
                  {'text': '聽聽聲音'},
                ],
              },
            ])
          : null;
      final directory = await Directory.systemTemp.createTemp(
        'generated-translation-settings-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final original = await File(
        '${directory.path}/voice.srt',
      ).writeAsString('1\n00:00:01,000 --> 00:00:02,000\n声を聴いて\n\n');
      final translated = await GeneratedSubtitleTranslationService().translate(
        original.path,
        saveTranslation: false,
        targetLocale: const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hant',
        ),
        cancelToken: CancelToken(),
        onProgress: (_) {},
      );
      expect(translated.translated.single.text, '聽聽聲音');
      expect(network.requests.map((uri) => uri.host), [
        'dict.youdao.com',
        'api.cognitive.microsofttranslator.com',
      ]);
      final microsoft = network.requests.last;
      expect(microsoft.queryParameters['to'], 'zh-Hant');
      expect(microsoft.queryParameters['from'], 'ja');
      expect(translated.savedPath, isNull);
    },
  );

  test(
    'falls back after Youdao network failure and reuses the success cache',
    () async {
      const text = '声を聴いて';
      network.responseFor = (uri) {
        if (uri.host == 'api.cognitive.microsofttranslator.com') {
          return _FakeReply.json(200, [
            {
              'translations': [
                {'text': 'Listen to the voice'},
              ],
            },
          ]);
        }
        return null;
      };

      final service = TranslationService();
      expect(
        await service.translate(text, sourceLang: 'ja'),
        'Listen to the voice',
      );
      final requestsAfterSuccess = network.requests.length;
      expect(network.requests.map((uri) => uri.host), [
        'dict.youdao.com',
        'api.cognitive.microsofttranslator.com',
      ]);

      expect(
        await service.translate(text, sourceLang: 'ja'),
        'Listen to the voice',
      );
      expect(network.requests, hasLength(requestsAfterSuccess));
    },
  );

  test(
    'returns the source without caching when every provider is offline',
    () async {
      const text = '声を聴いてください';
      final service = TranslationService();

      expect(await service.translate(text, sourceLang: 'ja'), text);
      final firstAttemptCount = network.requests.length;
      expect(firstAttemptCount, greaterThan(1));
      expect(
        network.requests.map((uri) => uri.host),
        contains('dict.youdao.com'),
      );
      expect(
        network.requests.map((uri) => uri.host),
        contains('api.cognitive.microsofttranslator.com'),
      );

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('translation_cache_ja_en_${text.hashCode}'),
        isNull,
      );
      expect(await service.translate(text, sourceLang: 'ja'), text);
      expect(network.requests.length, greaterThan(firstAttemptCount));
    },
  );

  test(
    'missing LLM key falls back without exposing or caching an error',
    () async {
      const text = '静かな時間';
      _configure(source: 'llm');
      network.responseFor = (uri) => uri.host == 'dict.youdao.com'
          ? _FakeReply.json(200, {
              'translateResult': [
                [
                  {'tgt': 'A quiet moment'},
                ],
              ],
            })
          : null;

      final translated = await TranslationService().translate(
        text,
        sourceLang: 'ja',
      );
      expect(translated, 'A quiet moment');
      expect(translated, isNot(startsWith('Error:')));
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(
          prefs.getString('translation_cache_ja_en_${text.hashCode}')!,
        )['translation'],
        translated,
      );
    },
  );

  test('LLM HTTP errors fall back without caching error text', () async {
    const text = '眠れる音楽';
    _configure(source: 'llm', apiKey: 'configured-key');
    network.responseFor = (uri) {
      if (uri.host == 'api.openai.com') {
        return _FakeReply.json(401, {
          'error': {'message': 'Unauthorized'},
        });
      }
      if (uri.host == 'dict.youdao.com') {
        return _FakeReply.json(200, {
          'translateResult': [
            [
              {'tgt': 'Sleep music'},
            ],
          ],
        });
      }
      return null;
    };

    final translated = await TranslationService().translate(
      text,
      sourceLang: 'ja',
    );
    expect(translated, 'Sleep music');
    expect(translated, isNot(startsWith('Error:')));
    final prefs = await SharedPreferences.getInstance();
    expect(
      jsonDecode(
        prefs.getString('translation_cache_ja_en_${text.hashCode}')!,
      )['translation'],
      translated,
    );
  });

  test(
    'Microsoft response parse failures allow the next source to succeed',
    () async {
      const text = '話を聞いて';
      _configure(source: 'microsoft');
      network.responseFor = (uri) {
        if (uri.host == 'api.cognitive.microsofttranslator.com') {
          return _FakeReply.json(200, [
            {'translations': []},
          ]);
        }
        if (uri.host == 'dict.youdao.com') {
          return _FakeReply.json(200, {
            'translateResult': [
              [
                {'tgt': 'Listen to the story'},
              ],
            ],
          });
        }
        return null;
      };

      expect(
        await TranslationService().translate(text, sourceLang: 'ja'),
        'Listen to the story',
      );
      expect(network.requests.map((uri) => uri.host), [
        'api.cognitive.microsofttranslator.com',
        'dict.youdao.com',
      ]);
    },
  );

  test(
    'accepts and caches a nonempty LLM result equal to the source',
    () async {
      const text = 'Hello';
      _configure(source: 'llm', apiKey: 'configured-key');
      network.responseFor = (uri) => uri.host == 'api.openai.com'
          ? _FakeReply.json(200, {
              'choices': [
                {
                  'message': {'content': text},
                },
              ],
            })
          : null;

      final service = TranslationService();
      expect(await service.translate(text, sourceLang: 'ja'), text);
      final requestCount = network.requests.length;
      expect(requestCount, 1);
      expect(await service.translate(text, sourceLang: 'ja'), text);
      expect(network.requests, hasLength(requestCount));
    },
  );

  test('does not cache an empty Google response', () async {
    const text = '話を聞いて';
    _configure(source: 'google');
    network.responseFor = (uri) => uri.host.contains('google')
        ? _FakeReply.json(200, [
            [
              ['  ', text, null, null, 1],
            ],
            null,
            'ja',
          ])
        : null;

    expect(await TranslationService().translate(text, sourceLang: 'ja'), text);
    expect(network.requests.first.host, contains('google'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('translation_cache_ja_en_${text.hashCode}'), isNull);
  });

  test(
    'keeps Youdao nested result concatenation without adding separators',
    () async {
      const text = '話して';
      network.responseFor = (uri) => uri.host == 'dict.youdao.com'
          ? _FakeReply.json(200, {
              'translateResult': [
                [
                  {'tgt': 'Talk'},
                  {'tgt': ' softly'},
                ],
                [
                  {'tgt': '\nnow'},
                ],
              ],
            })
          : null;

      expect(
        await TranslationService().translate(text, sourceLang: 'ja'),
        'Talk softly\nnow',
      );
      expect(network.requests.map((uri) => uri.host), ['dict.youdao.com']);
    },
  );

  test('retries cache entries containing known legacy LLM errors', () async {
    final prefs = await SharedPreferences.getInstance();
    network.responseFor = (uri) => uri.host == 'dict.youdao.com'
        ? _FakeReply.json(200, {
            'translateResult': [
              [
                {'tgt': 'Translate the story'},
              ],
            ],
          })
        : null;

    final service = TranslationService();
    for (final (text, staleError) in <(String, String)>[
      ('話を訳す', 'Error: API Key is missing. Please configure LLM settings.'),
      ('物語を訳す', 'Error: 401 - Unauthorized'),
      ('空の翻訳', '   '),
    ]) {
      final cacheKey = 'translation_cache_ja_en_${text.hashCode}';
      await prefs.setString(
        cacheKey,
        jsonEncode({
          'translation': staleError,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      expect(
        await service.translate(text, sourceLang: 'ja'),
        'Translate the story',
      );
      expect(
        jsonDecode(prefs.getString(cacheKey)!)['translation'],
        'Translate the story',
      );
    }
  });
}

void _configure({required String source, String? apiKey}) {
  SharedPreferences.setMockInitialValues({
    'locale_language': 'en',
    TranslationLanguagePreferencesNotifier.keyTargetLanguage: 'en',
    'translation_source': source,
    if (apiKey != null) 'llm_settings_api_key': apiKey,
  });
}

class _FakeHttpOverrides extends HttpOverrides {
  _FakeHttpOverrides();

  _FakeReply? Function(Uri uri) responseFor = (_) => null;
  final requests = <Uri>[];

  void reset() {
    responseFor = (_) => null;
    requests.clear();
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(this);
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.overrides);

  final _FakeHttpOverrides overrides;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    overrides.requests.add(url);
    final reply = overrides.responseFor(url);
    if (reply == null) throw const SocketException('offline');
    return _FakeHttpClientRequest(reply);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this.reply);

  final _FakeReply reply;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #headers) return _FakeHttpHeaders();
    if (invocation.memberName == #addStream) {
      return _discard(
        invocation.positionalArguments.single as Stream<List<int>>,
      );
    }
    if (invocation.memberName == #close) {
      return Future<HttpClientResponse>.value(_FakeHttpClientResponse(reply));
    }
    if (invocation.memberName == #flush) return Future<void>.value();
    return null;
  }

  Future<void> _discard(Stream<List<int>> stream) async {
    await for (final _ in stream) {}
  }
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this.reply)
    : headers = _FakeHttpHeaders({
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        HttpHeaders.contentLengthHeader: reply.body.length.toString(),
      });

  final _FakeReply reply;

  @override
  final HttpHeaders headers;

  @override
  int get contentLength => reply.body.length;

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => reply.statusCode == 200 ? 'OK' : 'Error';

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  int get statusCode => reply.statusCode;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(Uint8List.fromList(reply.body)).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpHeaders implements HttpHeaders {
  _FakeHttpHeaders([Map<String, String> values = const {}])
    : _values = {
        for (final entry in values.entries)
          entry.key.toLowerCase(): <String>[entry.value],
      };

  final Map<String, List<String>> _values;

  @override
  String? value(String name) => _values[name.toLowerCase()]?.join(', ');

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values.putIfAbsent(name.toLowerCase(), () => []).add(value.toString());
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = [value.toString()];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeReply {
  _FakeReply(this.statusCode, this.body);

  factory _FakeReply.json(int statusCode, Object body) {
    return _FakeReply(statusCode, utf8.encode(jsonEncode(body)));
  }

  final int statusCode;
  final List<int> body;
}
