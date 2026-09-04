import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  test(
    '24-hour work caches are isolated by server and account scope',
    () async {
      const alice = 'https://one.example|alice';
      const bob = 'https://one.example|bob';
      const otherServer = 'https://two.example|alice';

      await CacheService.cacheWorkDetail(42, {'owner': 'alice'}, scope: alice);
      await CacheService.cacheWorkTracks(
        42,
        jsonEncode(['alice-track']),
        scope: alice,
      );

      expect(await CacheService.getCachedWorkDetail(42, scope: alice), {
        'owner': 'alice',
      });
      expect(await CacheService.getCachedWorkDetail(42, scope: bob), isNull);
      expect(
        await CacheService.getCachedWorkDetail(42, scope: otherServer),
        isNull,
      );
      expect(
        jsonDecode((await CacheService.getCachedWorkTracks(42, scope: alice))!),
        ['alice-track'],
      );
      expect(await CacheService.getCachedWorkTracks(42, scope: bob), isNull);
    },
  );

  test('hashless content image keys use canonical token-free URLs', () {
    final first = CacheService.imageCacheKey(
      imageUrl: 'https://example.com/image/one.jpg?size=full&token=first',
      hash: '',
    );
    final rotatedToken = CacheService.imageCacheKey(
      imageUrl: 'https://example.com/image/one.jpg?token=second&size=full',
      hash: null,
    );
    final differentImage = CacheService.imageCacheKey(
      imageUrl: 'https://example.com/image/two.jpg?size=full&token=first',
      hash: '',
    );

    expect(first, rotatedToken);
    expect(first, startsWith('content_image_uri_'));
    expect(differentImage, isNot(first));
    expect(
      CacheService.imageCacheKey(
        imageUrl: 'https://example.com/ignored.jpg',
        hash: 'stable-hash',
      ),
      'content_image_stable-hash',
    );
  });
}
