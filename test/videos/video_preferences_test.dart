import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/videos/video_browse_preferences.dart';
import 'package:kikoeru_flutter/src/videos/video_search_history.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'video search history persists independently and supports removal',
    () async {
      SharedPreferences.setMockInitialValues({
        'search_history': 'audio history',
      });
      final history = VideoSearchHistoryNotifier();

      await history.add('actor');
      await history.add('category');
      await history.add('actor');

      expect(history.state.queries, ['actor', 'category']);
      var preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('search_history'), 'audio history');
      expect(
        preferences.getStringList(VideoSearchHistoryNotifier.preferenceKey),
        ['actor', 'category'],
      );

      await history.remove('actor');
      expect(history.state.queries, ['category']);
      await history.clear();
      expect(history.state.queries, isEmpty);
      preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getStringList(VideoSearchHistoryNotifier.preferenceKey),
        isEmpty,
      );
    },
  );

  test('video layout preference has its own persisted selection', () async {
    SharedPreferences.setMockInitialValues({'works_layout_type': 'list'});
    final preference = VideoBrowseLayoutNotifier();

    await preference.setLayout(LayoutType.smallGrid);

    final preferences = await SharedPreferences.getInstance();
    expect(preference.state, LayoutType.smallGrid);
    expect(preferences.getString('works_layout_type'), 'list');
    expect(
      preferences.getString(VideoBrowseLayoutNotifier.preferenceKey),
      'smallGrid',
    );
  });
}
