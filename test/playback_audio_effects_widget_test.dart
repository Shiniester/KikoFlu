import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_effects_settings.dart';
import 'package:kikoeru_flutter/src/providers/audio_effects_provider.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/native_audio_effects.dart';
import 'package:kikoeru_flutter/src/widgets/player/playback_audio_effects.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final locale in ['en', 'zh', 'ja']) {
    for (final width in [320.0, 1024.0]) {
      testWidgets('$locale effects panel fits $width with enlarged text', (
        tester,
      ) async {
        tester.view.reset();
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final container = ProviderContainer(
          overrides: [
            audioEffectsStatusProvider.overrideWith(
              (ref) => Stream.value(AudioEffectsStatus.ready),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: Locale(locale),
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.8)),
                child: child!,
              ),
              home: const Scaffold(body: PlaybackAudioEffectsDialog()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final switchTile = find.byType(SwitchListTile).first;
        await tester.ensureVisible(switchTile);
        await tester.tap(switchTile);
        await tester.pumpAndSettle();
        expect(
          container.read(audioEffectsSettingsProvider).equalizerEnabled,
          true,
        );
        final band = find.byKey(const ValueKey('audio-effects-band-0'));
        await tester.ensureVisible(band);
        await tester.pumpAndSettle();
        final semantics = tester.ensureSemantics();
        expect(tester.getSemantics(band).label, contains('31 Hz'));
        semantics.dispose();
        await tester.drag(band, const Offset(25, 0));
        await tester.pumpAndSettle();
        expect(
          container.read(audioEffectsSettingsProvider).gains[0],
          greaterThan(0),
        );
        final mode = find.byType(DropdownButtonFormField<BinauralMode>);
        await tester.ensureVisible(mode);
        await tester.pumpAndSettle();
        await tester.tap(mode);
        await tester.pumpAndSettle();
        final monoLabel = S.of(tester.element(mode)).audioEffectsBinauralMono;
        await tester.tap(find.text(monoLabel).last);
        await tester.pumpAndSettle();
        expect(
          container.read(audioEffectsSettingsProvider).binauralMode,
          BinauralMode.mono,
        );
        final amount = find.byKey(const ValueKey('audio-effects-mono-amount'));
        await tester.ensureVisible(amount);
        await tester.pumpAndSettle();
        await tester.drag(amount, const Offset(20, 0));
        await tester.pumpAndSettle();
        expect(
          container.read(audioEffectsSettingsProvider).monoAmount,
          greaterThan(50),
        );
        expect(container.read(audioEffectsSettingsProvider).stereoAmount, 50);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('passthrough explains bypass and retains editable settings', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'audio_passthrough': true});
    final container = ProviderContainer(
      overrides: [
        audioEffectsStatusProvider.overrideWith(
          (ref) => Stream.value(AudioEffectsStatus.unavailable),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(body: PlaybackAudioEffectsDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await container.read(audioPassthroughProvider.notifier).toggle(true);
    await tester.pumpAndSettle();
    expect(find.textContaining('Passthrough bypasses'), findsOneWidget);
    await container
        .read(audioEffectsSettingsProvider.notifier)
        .setPreset(EqualizerPreset.vocal);
    await tester.pumpAndSettle();
    expect(container.read(audioEffectsSettingsProvider).gains[6], 9);
  });
  testWidgets(
    'semantic reset tap resets the equalizer and preserves other modules',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final container = ProviderContainer(
          overrides: [
            audioEffectsStatusProvider.overrideWith(
              (ref) => Stream.value(AudioEffectsStatus.ready),
            ),
          ],
        );
        addTearDown(container.dispose);
        final notifier = container.read(audioEffectsSettingsProvider.notifier);
        await notifier.setPreset(EqualizerPreset.vocal);
        await notifier.setEqualizerEnabled(true);
        await notifier.setSceneAmount(72);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: Scaffold(body: PlaybackAudioEffectsDialog()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        tester.semantics.tap(find.semantics.byLabel('Reset Equalizer'));
        await tester.pumpAndSettle();
        expect(
          container.read(audioEffectsSettingsProvider).equalizerEnabled,
          false,
        );
        expect(
          container.read(audioEffectsSettingsProvider).gains,
          List.filled(10, 0),
        );
        expect(container.read(audioEffectsSettingsProvider).sceneAmount, 72);
      } finally {
        semantics.dispose();
      }
    },
  );
}
