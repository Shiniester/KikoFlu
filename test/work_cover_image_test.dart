import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/work_cover_image.dart';

class _PendingImage extends ImageProvider<_PendingImage> {
  final frame = Completer<ImageInfo>();

  @override
  Future<_PendingImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _PendingImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(frame.future);
}

void main() {
  testWidgets(
    'cover shows initial placeholder, replaces identity and handles failure',
    (tester) async {
      final ui.Image? decoded = await tester.runAsync(
        () => createTestImage(width: 80, height: 60),
      );
      addTearDown(decoded!.dispose);
      final first = _PendingImage();
      final second = _PendingImage();
      final retry = _PendingImage();
      final source = ValueNotifier<ImageProvider>(first);
      addTearDown(source.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ValueListenableBuilder<ImageProvider>(
              valueListenable: source,
              builder: (context, image, _) => WorkCoverImage(
                image: image,
                width: 80,
                height: 60,
                placeholder: (_) => const Text('Loading cover'),
                errorBuilder: (_, __, ___) => const Text('Cover failed'),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Loading cover'), findsOneWidget);
      expect(tester.getSize(find.byType(WorkCoverImage)), const Size(80, 60));
      first.frame.complete(ImageInfo(image: decoded.clone()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text('Loading cover'), findsNothing);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      source.value = second;
      await tester.pump();
      expect(find.text('Loading cover'), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);
      second.frame.completeError(StateError('cover unavailable'));
      await tester.pump();
      expect(find.text('Cover failed'), findsOneWidget);
      expect(tester.getSize(find.byType(WorkCoverImage)), const Size(80, 60));
      source.value = retry;
      await tester.pump();
      expect(find.text('Loading cover'), findsOneWidget);
      retry.frame.complete(ImageInfo(image: decoded.clone()));
      await tester.pumpAndSettle();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache.clear();
    },
  );
}
