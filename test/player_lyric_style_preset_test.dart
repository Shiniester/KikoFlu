import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/player_lyric_style_provider.dart';
import 'package:kikoeru_flutter/src/screens/player_lyric_style_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('spring presets keep stable ids and nominal parameters', () {
    const expected = <(String, double, double, double)>[
      ('default', 0.9, 15, 90),
      ('smooth', 1.2, 22, 80),
      ('responsive', 0.5, 18, 150),
      ('jello', 0.6, 8, 120),
      ('heavy', 2, 25, 60),
      ('noBounce', 1, 30, 100),
    ];

    for (final (id, mass, damping, stiffness) in expected) {
      final preset = PlayerLyricSpringPreset.fromId(id);
      expect(preset.id, id);
      expect(preset.mass, mass);
      expect(preset.damping, damping);
      expect(preset.stiffness, stiffness);
    }
  });

  test('missing and unknown spring preset ids use the default', () {
    expect(
      PlayerLyricSpringPreset.fromId(null),
      PlayerLyricSpringPreset.defaultPreset,
    );
    expect(
      PlayerLyricSpringPreset.fromId('future-preset'),
      PlayerLyricSpringPreset.defaultPreset,
    );
  });

  test(
    'spring preset choices survive storage reload and provider recreation',
    () async {
      for (final expected in PlayerLyricSpringPreset.values) {
        final container = ProviderContainer();
        final notifier = container.read(playerLyricSettingsProvider.notifier);
        await notifier.updateSpringPreset(expected);
        expect(
          container.read(playerLyricSettingsProvider).springPreset,
          expected,
        );

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('player_lyric_spring_preset'), expected.id);
        await prefs.reload();
        container.dispose();

        final restoredContainer = ProviderContainer();
        restoredContainer.read(playerLyricSettingsProvider);
        await _settlePreferences();
        expect(
          restoredContainer.read(playerLyricSettingsProvider).springPreset,
          expected,
        );
        restoredContainer.dispose();
      }
    },
  );

  test(
    'settings notifier defaults missing and unknown stored preset ids',
    () async {
      for (final values in <Map<String, Object>>[
        {},
        {'player_lyric_spring_preset': 'future-preset'},
      ]) {
        SharedPreferences.setMockInitialValues(values);
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final container = ProviderContainer();
        container.read(playerLyricSettingsProvider);
        await _settlePreferences();

        expect(
          container.read(playerLyricSettingsProvider).springPreset,
          PlayerLyricSpringPreset.defaultPreset,
        );
        container.dispose();
      }
    },
  );

  test('reset restores and persists the default spring preset', () async {
    SharedPreferences.setMockInitialValues({
      'player_lyric_spring_preset': 'noBounce',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(playerLyricSettingsProvider.notifier).reset();
    await _settlePreferences();

    expect(
      container.read(playerLyricSettingsProvider).springPreset,
      PlayerLyricSpringPreset.defaultPreset,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('player_lyric_spring_preset'), 'default');
  });

  testWidgets('lyric style screen lets users select a spring preset', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: PlayerLyricStyleScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final presetDropdown = find.byKey(
      const ValueKey('player-lyric-spring-preset'),
    );
    expect(presetDropdown, findsOneWidget);
    await tester.ensureVisible(presetDropdown);
    await tester.pumpAndSettle();
    await tester.tap(presetDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Responsive').last);
    await tester.pumpAndSettle();

    expect(
      container.read(playerLyricSettingsProvider).springPreset,
      PlayerLyricSpringPreset.responsive,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('player_lyric_spring_preset'), 'responsive');
  });

  testWidgets('spring preset choices use every supported localization', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const choices = <(Locale, List<String>)>[
      (
        Locale('en'),
        ['Default', 'Smooth', 'Responsive', 'Jello', 'Heavy', 'No Bounce'],
      ),
      (Locale('ja'), ['標準', 'なめらか', '追従重視', 'ジェリー', '重厚', '弾まない']),
      (Locale('zh'), ['默认', '更平滑', '快速跟手', '果冻感', '厚重缓慢', '无弹跳']),
      (
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        ['預設', '更平滑', '快速跟隨', '果凍感', '厚重緩慢', '無彈跳'],
      ),
    ];

    for (final (locale, labels) in choices) {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: locale,
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: const PlayerLyricStyleScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final presetDropdown = find.byKey(
        const ValueKey('player-lyric-spring-preset'),
      );
      await tester.ensureVisible(presetDropdown);
      await tester.pumpAndSettle();
      await tester.tap(presetDropdown);
      await tester.pumpAndSettle();

      for (final label in labels) {
        expect(find.text(label), findsWidgets);
      }
      await tester.tap(find.text(labels.first).last);
      await tester.pumpAndSettle();
    }
  });
}

Future<void> _settlePreferences() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
