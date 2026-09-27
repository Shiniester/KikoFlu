import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/enhanced_work_card.dart';
import 'package:kikoeru_flutter/src/widgets/virtualized_sliver_collection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final columns in [1, 2, 3]) {
    testWidgets(
      'audio covers retain their decoded frame on reverse scroll ($columns columns)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final directory = await tester.runAsync(() async {
          final dir = await Directory.systemTemp.createTemp(
            'audio-cover-test-',
          );
          final bytes = img.encodePng(img.Image(width: 80, height: 60));
          for (var i = 0; i < 40; i++) {
            final file = await File('${dir.path}/$i.png').writeAsBytes(bytes);
            final stream = FileImage(file).resolve(ImageConfiguration.empty);
            final ready = Completer<void>();
            final listener = ImageStreamListener((_, __) => ready.complete());
            stream.addListener(listener);
            await ready.future;
            stream.removeListener(listener);
          }
          return dir;
        });
        addTearDown(() => directory!.delete(recursive: true));
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final items = ValueNotifier(List.generate(40, (i) => i));
        addTearDown(items.dispose);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: Scaffold(
                body: ValueListenableBuilder<List<int>>(
                  valueListenable: items,
                  builder: (context, values, _) =>
                      VirtualizedSliverCollection<int>(
                        items: values,
                        itemId: (id) => id,
                        controller: scroll,
                        retainedItemCount: 100,
                        layout: columns == 1
                            ? VirtualizedCollectionLayout.list
                            : VirtualizedCollectionLayout.masonry,
                        masonryCrossAxisCount: columns,
                        itemBuilder: (context, id, _) => EnhancedWorkCard(
                          key: ValueKey(id),
                          work: Work(id: id, title: 'Audio $id'),
                          crossAxisCount: columns,
                          isListLayout: columns == 1,
                          localCoverPath: '${directory!.path}/$id.png',
                        ),
                      ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final card = find.byKey(const ValueKey(0));
        final imageFinder = find.descendant(
          of: card,
          matching: find.byType(Image),
        );
        await tester.runAsync(() async {
          final image = tester.widget<Image>(imageFinder);
          final stream = image.image.resolve(ImageConfiguration.empty);
          final ready = Completer<void>();
          final listener = ImageStreamListener(
            (_, __) {
              if (!ready.isCompleted) ready.complete();
            },
            onError: (Object error, StackTrace? stack) =>
                ready.completeError(error, stack),
          );
          stream.addListener(listener);
          try {
            await ready.future.timeout(const Duration(seconds: 5));
          } finally {
            stream.removeListener(listener);
          }
        });
        await tester.pump();
        await tester.pump();
        final originalState = tester.state(card);
        final raw = find.descendant(of: card, matching: find.byType(RawImage));
        final originalImage = tester.widget<RawImage>(raw).image!;
        await tester.scrollUntilVisible(find.text('Audio 39'), 500);
        await tester.pump();
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        scroll.jumpTo(0);
        await tester.pump();
        expect(tester.state(card), same(originalState));
        expect(tester.widget<RawImage>(raw).image, same(originalImage));
        items.value = [39];
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const ValueKey(0), skipOffstage: false),
          findsNothing,
        );
        expect(originalImage.debugDisposed, isTrue);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
