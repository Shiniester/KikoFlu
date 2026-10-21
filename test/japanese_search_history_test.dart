import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/search_history_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _searchParams(String sourcePath) => {
  'source': 'jpAsmr',
  'conditions': [
    {
      'searchType': 'tag',
      'value': 'Display name',
      'isExclude': false,
      'sourcePath': sourcePath,
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'retains distinct JP taxonomy paths and deduplicates repeated queries',
    () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final loaded = Completer<void>();
      final subscription = container.listen(searchHistoryProvider, (_, state) {
        if (!state.isLoading && !loaded.isCompleted) loaded.complete();
      }, fireImmediately: true);
      addTearDown(subscription.close);
      await loaded.future;

      final history = container.read(searchHistoryProvider.notifier);
      await history.addHistory(
        keyword: '',
        displayText: 'Tag: Ear',
        searchParams: _searchParams('/tag/%e8%80%b3/'),
      );
      await history.addHistory(
        keyword: '',
        displayText: 'Tag: Binaural',
        searchParams: _searchParams('/tag/binaural/'),
      );
      await history.addHistory(
        keyword: '',
        displayText: 'Tag: Ear',
        searchParams: _searchParams('/tag/%e8%80%b3/'),
      );

      final items = container.read(searchHistoryProvider).items;
      expect(items, hasLength(2));
      expect(
        items.map((item) => item.searchParams!['conditions'][0]['sourcePath']),
        ['/tag/%e8%80%b3/', '/tag/binaural/'],
      );
      final restored = SearchHistoryItem.fromJson(items.first.toJson());
      expect(restored.searchParams!['source'], 'jpAsmr');
      expect(
        restored.searchParams!['conditions'][0]['sourcePath'],
        '/tag/%e8%80%b3/',
      );
      expect(restored, items.first);
    },
  );
}
