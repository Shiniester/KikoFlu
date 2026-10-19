import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/my_tabs_display_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('audio page order persists independently of comic order', () async {
    SharedPreferences.setMockInitialValues({
      'comic_collection_page_order': '3,1,2',
      'my_tabs_show_online_marks': false,
    });
    final preferences = await SharedPreferences.getInstance();
    final settings = MyTabsDisplaySettingsNotifier();
    addTearDown(settings.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(settings.state.showOnlineMarks, isFalse);

    final order = MyTabsDisplaySettings.defaultPageOrder.reversed.toList();
    await settings.setPageOrder(order);
    expect(settings.state.pageOrder, order);
    expect(preferences.getStringList('my_tabs_page_order'), order);
    expect(preferences.getString('comic_collection_page_order'), '3,1,2');
    expect(settings.state.showOnlineMarks, isFalse);

    final restored = MyTabsDisplaySettingsNotifier();
    addTearDown(restored.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(restored.state.pageOrder, order);
    await restored.resetToDefault();
    expect(restored.state.pageOrder, MyTabsDisplaySettings.defaultPageOrder);
    expect(
      preferences.getStringList('my_tabs_page_order'),
      MyTabsDisplaySettings.defaultPageOrder,
    );
    expect(preferences.getString('comic_collection_page_order'), '3,1,2');
  });
}
