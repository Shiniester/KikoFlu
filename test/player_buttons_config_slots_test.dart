import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/player_buttons_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('player actions split at an explicit slot count without reordering', () {
    const config = PlayerButtonsConfig.defaultDesktop;

    final visible = config.getVisibleButtons(slotCount: 3);
    final overflow = config.getMoreButtons(slotCount: 3);

    expect(visible, config.buttonOrder.take(3));
    expect(overflow, config.buttonOrder.skip(3));
    expect([...visible, ...overflow], config.buttonOrder);
  });

  test('zero visible slots keeps every configured action in overflow', () {
    const config = PlayerButtonsConfig.defaultMobile;

    expect(config.getVisibleButtons(slotCount: 0), isEmpty);
    expect(config.getMoreButtons(slotCount: 0), config.buttonOrder);
  });

  test('new default exposes the five configured bottom actions', () {
    expect(
      PlayerButtonsConfig.defaultMobile.getVisibleButtons(slotCount: 5),
      const [
        PlayerButtonType.repeat,
        PlayerButtonType.seekBackward,
        PlayerButtonType.mark,
        PlayerButtonType.seekForward,
        PlayerButtonType.queue,
      ],
    );
  });

  test(
    'the previous Salt default is migrated without touching custom order',
    () async {
      SharedPreferences.setMockInitialValues({
        'player_buttons_config': PlayerButtonsConfig.previousDefaultMobile
            .map((button) => button.key)
            .join(','),
      });
      final controller = PlayerButtonsConfigController(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        controller.state.buttonOrder,
        PlayerButtonsConfig.defaultMobile.buttonOrder,
      );
      controller.dispose();
    },
  );

  test(
    'legacy default is migrated once but a custom order is preserved',
    () async {
      SharedPreferences.setMockInitialValues({
        'player_buttons_config': PlayerButtonsConfig.legacyDefaultMobile
            .map((button) => button.key)
            .join(','),
      });
      final legacy = PlayerButtonsConfigController(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        legacy.state.buttonOrder,
        PlayerButtonsConfig.defaultMobile.buttonOrder,
      );
      legacy.dispose();

      const custom = [
        PlayerButtonType.speed,
        PlayerButtonType.seekBackward,
        PlayerButtonType.repeat,
      ];
      SharedPreferences.setMockInitialValues({
        'player_buttons_config': custom.map((button) => button.key).join(','),
      });
      final customized = PlayerButtonsConfigController(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(customized.state.buttonOrder.take(3), custom);
      customized.dispose();
    },
  );
}
