import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/utils/system_ui_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpAsyncPreferenceLoad() async {
  for (var index = 0; index < 5; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SystemUiModeCoordinator.instance.debugResetState();
  });

  test('hide status bar defaults to disabled', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(hideStatusBarProvider), false);
    await _pumpAsyncPreferenceLoad();

    expect(container.read(hideStatusBarProvider), false);
  });

  test('hide status bar loads the saved preference', () async {
    SharedPreferences.setMockInitialValues({
      SystemUiModeCoordinator.hideStatusBarPreferenceKey: true,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(hideStatusBarProvider), false);
    await _pumpAsyncPreferenceLoad();

    expect(container.read(hideStatusBarProvider), true);
  });

  test('hide status bar persists updates', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(hideStatusBarProvider.notifier).setEnabled(true);
    final preferences = await SharedPreferences.getInstance();

    expect(container.read(hideStatusBarProvider), true);
    expect(
      preferences.getBool(SystemUiModeCoordinator.hideStatusBarPreferenceKey),
      true,
    );
  });
}
