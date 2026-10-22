import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/services/audio_variant_selection.dart';
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';
import 'package:kikoeru_flutter/src/widgets/audio_variant_selection_sheet.dart';
import 'package:kikoeru_flutter/src/widgets/responsive_dialog.dart';

Widget _testApp(Widget home) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: S.localizationsDelegates,
  supportedLocales: S.supportedLocales,
  home: home,
);

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('narrow sheet switches candidates and confirms the selection', (
    tester,
  ) async {
    _setSize(tester, const Size(390, 800));
    final target = _variant(
      title: '01 narration track.mp3',
      path: '01/narration track.mp3',
    );
    final alternate = _variant(
      title: '01 narration track (mix).wav',
      path: 'alternate/01 narration track.wav',
      format: AudioFormat.wav,
    );
    final unrelated = _variant(
      title: 'rain over the forest.wav',
      path: 'ambient/rain.wav',
      format: AudioFormat.wav,
    );
    Future<List<AudioVariantSelection>?>? result;

    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                result = showAudioVariantSelectionSheet(
                  context,
                  targets: [target],
                  allVariants: [target, alternate, unrelated],
                  purpose: AudioVariantSelectionPurpose.subtitleGeneration,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('audio-variant-group-${target.fullPath}')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        ValueKey(
          'audio-variant-option-${target.fullPath}-${alternate.fullPath}',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        ValueKey(
          'audio-variant-option-${target.fullPath}-${unrelated.fullPath}',
        ),
      ),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('audio-variant-toggle-all')));
    await tester.pump();
    expect(
      find.byKey(
        ValueKey(
          'audio-variant-option-${target.fullPath}-${unrelated.fullPath}',
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('audio-variant-toggle-all')));
    await tester.pump();

    await tester.tap(
      find.byKey(
        ValueKey(
          'audio-variant-option-${target.fullPath}-${alternate.fullPath}',
        ),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('audio-variant-selection-confirm')),
    );
    await tester.pumpAndSettle();

    final selections = await result;
    expect(selections, hasLength(1));
    expect(selections!.single.target, same(target));
    expect(selections.single.selected, same(alternate));
    expect(tester.takeException(), isNull);
  });

  testWidgets('skipping a group omits it when confirming', (tester) async {
    _setSize(tester, const Size(390, 800));
    final first = _variant(title: 'first narration.wav', path: 'first.wav');
    final second = _variant(title: 'second narration.wav', path: 'second.wav');
    Future<List<AudioVariantSelection>?>? result;

    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                result = showAudioVariantSelectionSheet(
                  context,
                  targets: [first, second],
                  allVariants: [first, second],
                  purpose: AudioVariantSelectionPurpose.download,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('audio-variant-skip-${first.fullPath}')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('audio-variant-selection-confirm')),
    );
    await tester.pumpAndSettle();

    final selections = await result;
    expect(selections, hasLength(1));
    expect(selections!.single.target, same(second));
  });

  testWidgets('cancel returns null', (tester) async {
    _setSize(tester, const Size(390, 800));
    final target = _variant(title: 'track.wav', path: 'track.wav');
    Future<List<AudioVariantSelection>?>? result;

    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                result = showAudioVariantSelectionSheet(
                  context,
                  targets: [target],
                  allVariants: [target],
                  purpose: AudioVariantSelectionPurpose.download,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('audio-variant-selection-cancel')),
    );
    await tester.pumpAndSettle();

    expect(await result, isNull);
  });

  testWidgets('wide sheet scrolls through 40 groups without overflow', (
    tester,
  ) async {
    _setSize(tester, const Size(1000, 800));
    final targets = [
      for (var index = 0; index < 40; index++)
        _variant(
          title: 'item ${String.fromCharCode(0x4e00 + index)}.mp3',
          path: 'track-$index.mp3',
        ),
    ];

    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAudioVariantSelectionSheet(
                context,
                targets: targets,
                allVariants: targets,
                purpose: AudioVariantSelectionPurpose.download,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(ResponsiveBottomSheet), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(ValueKey('audio-variant-group-${targets.last.fullPath}')),
      500,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('audio-variant-group-list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}

PlayerAudioVariant _variant({
  required String title,
  required String path,
  AudioFormat format = AudioFormat.mp3,
}) => PlayerAudioVariant(
  source: const {'size': 1024},
  title: title,
  parentPath: path,
  fullPath: path,
  format: format,
  subtitleLanguage: PlayerSubtitleLanguage.unknown,
  se: PlayerBinaryTrait.unknown,
  ejaculation: PlayerBinaryTrait.unknown,
);
