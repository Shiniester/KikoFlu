import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

const _sheetSurfaceKey = ValueKey('responsive-sheet-surface');
const _openEffectsKey = ValueKey('open-effects');

ProviderContainer _container() => ProviderContainer(
  overrides: [
    audioEffectsStatusProvider.overrideWith(
      (ref) => Stream.value(AudioEffectsStatus.ready),
    ),
  ],
);

Widget _testApp(
  ProviderContainer container, {
  double textScale = 1,
  Locale locale = const Locale('en'),
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    locale: locale,
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            key: _openEffectsKey,
            onPressed: () => showPlaybackAudioEffects(context),
            child: const Text('Open effects'),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _openEffects(WidgetTester tester) async {
  await tester.tap(find.byKey(_openEffectsKey));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('opens as a responsive sheet without binaural controls', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = _container();
    addTearDown(container.dispose);

    for (final locale in ['en', 'zh', 'ja']) {
      for (final size in [const Size(320, 844), const Size(1024, 844)]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          _testApp(container, textScale: 1.8, locale: Locale(locale)),
        );
        await _openEffects(tester);

        expect(find.byKey(_sheetSurfaceKey), findsOneWidget);
        expect(find.byType(Dialog), findsNothing);
        expect(
          find.text(
            S
                .of(tester.element(find.byKey(_sheetSurfaceKey)))
                .audioEffectsBinaural,
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);

        final sheetRect = tester.getRect(find.byKey(_sheetSurfaceKey));
        if (size.width > size.height) {
          expect(sheetRect.right, closeTo(size.width, 0.1));
          expect(sheetRect.height, closeTo(size.height, 0.1));
        } else {
          expect(sheetRect.bottom, closeTo(size.height, 0.1));
          await tester.ensureVisible(
            find.byKey(const ValueKey('audio-effects-band-9')),
          );
          await tester.pumpAndSettle();
          final equalizerTitle = find
              .descendant(
                of: find.byKey(const PageStorageKey('audio-effects-equalizer')),
                matching: find.text(
                  S
                      .of(tester.element(find.byKey(_sheetSurfaceKey)))
                      .audioEffectsEqualizer,
                ),
              )
              .first;
          await tester.ensureVisible(equalizerTitle);
          await tester.tap(equalizerTitle);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('audio-effects-band-0')),
            findsNothing,
          );
          for (final key in ['audio-effects-channel', 'audio-effects-scene']) {
            final section = find.byKey(PageStorageKey(key));
            await tester.ensureVisible(section);
            await tester.tap(section);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }

        await tester.tap(find.byIcon(Icons.close));
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('collapsing the equalizer reduces the sheet height', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(_testApp(container));
    await _openEffects(tester);
    final originalHeight = tester.getSize(find.byKey(_sheetSurfaceKey)).height;
    await tester.tap(find.text('Equalizer').first);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(_sheetSurfaceKey)).height,
      lessThan(originalHeight),
    );
  });

  testWidgets('long preset remains visible with enlarged Japanese text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = _container();
    addTearDown(container.dispose);
    await container
        .read(audioEffectsSettingsProvider.notifier)
        .setPreset(EqualizerPreset.tappingDull);
    await tester.pumpWidget(
      _testApp(container, textScale: 1.8, locale: const Locale('ja')),
    );
    await _openEffects(tester);
    final labels = S.of(tester.element(find.byKey(_sheetSurfaceKey)));
    final selected = find.text(labels.audioEffectsDull).first;
    final text = tester.renderObject<RenderParagraph>(selected);
    final richText = tester.widget<RichText>(
      find.descendant(of: selected, matching: find.byType(RichText)).first,
    );
    final painter = TextPainter(
      text: richText.text,
      textDirection: TextDirection.ltr,
      textScaler: richText.textScaler,
    )..layout(maxWidth: text.size.width);
    try {
      expect(painter.computeLineMetrics().length, greaterThan(1));
      expect(text.size.height + 0.1, greaterThanOrEqualTo(painter.height));
    } finally {
      painter.dispose();
    }
  });

  testWidgets(
    'vertical equalizer sliders work and sections expand independently',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = _container();
      addTearDown(container.dispose);
      await tester.pumpWidget(_testApp(container));
      await _openEffects(tester);

      final labels = S.of(tester.element(find.byKey(_sheetSurfaceKey)));
      final equalizerSwitch = find.descendant(
        of: find.byKey(const PageStorageKey('audio-effects-equalizer')),
        matching: find.byType(Switch),
      );
      await tester.ensureVisible(equalizerSwitch);
      final switchSemantics = tester.ensureSemantics();
      try {
        expect(
          tester.getSemantics(equalizerSwitch).label,
          contains(labels.audioEffectsEqualizer),
        );
      } finally {
        switchSemantics.dispose();
      }
      await tester.tap(equalizerSwitch);
      await tester.pumpAndSettle();
      expect(
        container.read(audioEffectsSettingsProvider).equalizerEnabled,
        isTrue,
      );

      final preset = find.byType(DropdownButtonFormField<EqualizerPreset>);
      await tester.ensureVisible(preset);
      await tester.tap(preset);
      await tester.pumpAndSettle();
      await tester.tap(find.text(labels.audioEffectsVocal).last);
      await tester.pumpAndSettle();
      expect(container.read(audioEffectsSettingsProvider).gains[6], 9);

      final band = find.byKey(const ValueKey('audio-effects-band-0'));
      await tester.ensureVisible(band);
      expect(
        tester.getRect(band).height,
        greaterThan(tester.getRect(band).width),
      );
      final semantics = tester.ensureSemantics();
      try {
        expect(tester.getSemantics(band).label, contains('31 Hz'));
      } finally {
        semantics.dispose();
      }
      await tester.drag(band, const Offset(0, -35));
      await tester.pumpAndSettle();
      expect(
        container.read(audioEffectsSettingsProvider).gains.first,
        greaterThan(-3),
      );

      final channelSection = find.byKey(
        const PageStorageKey('audio-effects-channel'),
      );
      final sceneSection = find.byKey(
        const PageStorageKey('audio-effects-scene'),
      );
      final channelTitle = find
          .descendant(
            of: channelSection,
            matching: find.text(labels.audioEffectsChannel),
          )
          .first;
      final sceneTitle = find
          .descendant(
            of: sceneSection,
            matching: find.text(labels.audioEffectsScene),
          )
          .first;

      expect(
        find.byType(DropdownButtonFormField<AudioChannelMode>),
        findsNothing,
      );
      expect(find.byType(DropdownButtonFormField<AudioScene>), findsNothing);
      final sceneSwitch = find.descendant(
        of: sceneSection,
        matching: find.byType(Switch),
      );
      await tester.ensureVisible(sceneSwitch);
      await tester.tap(sceneSwitch);
      await tester.pumpAndSettle();
      expect(container.read(audioEffectsSettingsProvider).sceneEnabled, isTrue);
      expect(find.byType(DropdownButtonFormField<AudioScene>), findsNothing);

      await tester.ensureVisible(channelTitle);
      await tester.tap(channelTitle);
      await tester.pumpAndSettle();
      expect(
        find.byType(DropdownButtonFormField<AudioChannelMode>),
        findsOneWidget,
      );
      expect(find.byType(DropdownButtonFormField<AudioScene>), findsNothing);

      await tester.ensureVisible(sceneTitle);
      await tester.tap(sceneTitle);
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField<AudioScene>), findsOneWidget);

      final channelDropdown = find.byType(
        DropdownButtonFormField<AudioChannelMode>,
      );
      await tester.ensureVisible(channelDropdown);
      await tester.tap(channelDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text(labels.audioEffectsSwap).last);
      await tester.pumpAndSettle();
      expect(
        container.read(audioEffectsSettingsProvider).channelMode,
        AudioChannelMode.swap,
      );

      expect(container.read(audioEffectsSettingsProvider).sceneEnabled, isTrue);
      final sceneAmount = find.byKey(
        const ValueKey('audio-effects-scene-amount'),
      );
      await tester.ensureVisible(sceneAmount);
      await tester.drag(sceneAmount, const Offset(20, 0));
      await tester.pumpAndSettle();
      expect(
        container.read(audioEffectsSettingsProvider).sceneAmount,
        greaterThan(50),
      );

      await tester.ensureVisible(channelTitle);
      await tester.tap(channelTitle);
      await tester.pumpAndSettle();
      expect(
        find.byType(DropdownButtonFormField<AudioChannelMode>),
        findsNothing,
      );
      expect(find.byType(DropdownButtonFormField<AudioScene>), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('module reset preserves settings in other sections', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    final notifier = container.read(audioEffectsSettingsProvider.notifier);
    await notifier.setPreset(EqualizerPreset.vocal);
    await notifier.setEqualizerEnabled(true);
    await notifier.setSceneAmount(72);

    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(_testApp(container));
      await _openEffects(tester);

      tester.semantics.tap(find.semantics.byLabel('Reset Equalizer'));
      await tester.pumpAndSettle();
      final settings = container.read(audioEffectsSettingsProvider);
      expect(settings.equalizerEnabled, isFalse);
      expect(settings.gains, List.filled(10, 0));
      expect(settings.sceneAmount, 72);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('passthrough status and preset editing remain available', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(_testApp(container));
    await _openEffects(tester);
    await container.read(audioPassthroughProvider.notifier).toggle(true);
    await tester.pumpAndSettle();

    expect(find.textContaining('Passthrough bypasses'), findsOneWidget);
    await container
        .read(audioEffectsSettingsProvider.notifier)
        .setPreset(EqualizerPreset.vocal);
    await tester.pumpAndSettle();
    expect(container.read(audioEffectsSettingsProvider).gains[6], 9);
  });
}
