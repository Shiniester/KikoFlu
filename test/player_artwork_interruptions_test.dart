import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_cover_widget.dart';

class _PendingImage extends ImageProvider<_PendingImage> {
  final ready = Completer<ImageInfo>();
  @override
  Future<_PendingImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    _PendingImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(ready.future);
}

void main() {
  testWidgets(
    'artwork ignores out-of-order completion and clears motion when settings change',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final image = (await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(
          File('assets/icons/app_icon_opaque.png').readAsBytesSync(),
        );
        final image = (await codec.getNextFrame()).image;
        codec.dispose();
        return image;
      }))!;
      addTearDown(image.dispose);
      final providers = List.generate(4, (_) => _PendingImage());
      final track = ValueNotifier(0);
      final reduced = ValueNotifier(false);
      addTearDown(track.dispose);
      addTearDown(reduced.dispose);
      providers[0].ready.complete(ImageInfo(image: image.clone()));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: ValueListenableBuilder<bool>(
              valueListenable: reduced,
              builder: (context, disabled, _) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: disabled),
                child: ValueListenableBuilder<int>(
                  valueListenable: track,
                  builder: (context, index, _) => Scaffold(
                    body: PlayerCoverWidget(
                      track: AudioTrack(
                        id: 'track-$index',
                        title: '$index',
                        url: '$index.mp3',
                        workId: index,
                      ),
                      animateTrackChanges: true,
                      imageProviderOverride: providers[index],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      track.value = 1;
      await tester.pump();
      track.value = 2;
      await tester.pump();
      providers[2].ready.complete(ImageInfo(image: image.clone()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 45));
      final incoming = find.byKey(
        const ValueKey('player-cover-incoming-opacity'),
      );
      final opacity = tester.widget<FadeTransition>(incoming).opacity.value;
      final scaleFinder = find.byKey(
        const ValueKey('player-cover-incoming-scale'),
      );
      final scale = tester.widget<ScaleTransition>(scaleFinder).scale.value;
      providers[1].ready.complete(ImageInfo(image: image.clone()));
      await tester.pump();
      expect(tester.widget<FadeTransition>(incoming).opacity.value, opacity);
      expect(tester.widget<ScaleTransition>(scaleFinder).scale.value, scale);
      reduced.value = true;
      await tester.pump();
      expect(
        find.byKey(const ValueKey('player-cover-transition-stack')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('player-cover-artwork-track-2')),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('player-cover-artwork-track-2')),
        findsOneWidget,
      );
      reduced.value = false;
      await tester.pump();
      track.value = 3;
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      providers[3].ready.complete(ImageInfo(image: image.clone()));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
