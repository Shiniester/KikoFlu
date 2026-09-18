import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/providers/subtitle_library_provider.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/screens/works_screen.dart';
import 'package:kikoeru_flutter/src/screens/local_downloads_screen.dart';
import 'package:kikoeru_flutter/src/screens/search_screen.dart';
import 'package:kikoeru_flutter/src/widgets/image_gallery_screen.dart';
import 'package:kikoeru_flutter/src/widgets/search_condition_chip.dart';
import 'package:kikoeru_flutter/src/widgets/virtualized_sliver_collection.dart';

class _SubtitleLibrary extends SubtitleLibraryNotifier {
  @override
  Future<void> refresh() async {}
}

class _Works extends WorksNotifier {
  _Works(Ref ref) : super(KikoeruApiService(), ref) {
    state = WorksState(
      layoutType: LayoutType.list,
      modeStates: {
        for (final mode in DisplayMode.values)
          mode: WorksModeSnapshot(
            works: List.generate(
              30,
              (i) => Work(id: i + 1, title: '${mode.name} $i'),
            ),
            hasMore: false,
          ),
      },
    );
  }
  int loadMoreCalls = 0;
  int refreshCalls = 0;
  @override
  Future<void> loadMore() async {
    loadMoreCalls++;
  }

  @override
  Future<void> refresh({bool resetPage = false}) async {
    refreshCalls++;
    state = state.copyWith(
      modeStates: {
        ...state.modeStates,
        state.displayMode: const WorksModeSnapshot(isLoading: true),
      },
    );
  }

  void clearMode(DisplayMode mode) {
    state = state.copyWith(
      modeStates: {...state.modeStates, mode: const WorksModeSnapshot()},
    );
  }
}

Widget _app(Widget child, {ValueNotifier<bool>? reduced}) => MaterialApp(
  localizationsDelegates: S.localizationsDelegates,
  supportedLocales: S.supportedLocales,
  home: reduced == null
      ? child
      : ValueListenableBuilder<bool>(
          valueListenable: reduced,
          builder: (context, value, _) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: value),
            child: child,
          ),
        ),
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({'works_layout_type': 'list'});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets(
    '40ms home round trips isolate controllers and restore position',
    (tester) async {
      late _Works works;
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            worksProvider.overrideWith((ref) => works = _Works(ref)),
            subtitleLibraryProvider.overrideWith((ref) => _SubtitleLibrary()),
            downloadSummaryProvider.overrideWith(
              (ref) => Stream.value(const DownloadTaskSummary.empty()),
            ),
          ],
          child: _app(const WorksScreen(), reduced: reduced),
        ),
      );
      await tester.pumpAndSettle();
      final first = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      first.jumpTo(600);
      await tester.pump();
      works.setDisplayMode(DisplayMode.popular);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(first.positions.length, 1);
      final controllers = tester
          .widgetList<CustomScrollView>(find.byType(CustomScrollView))
          .map((w) => w.controller!)
          .toList();
      expect(controllers.toSet().length, 2);
      for (final controller in controllers) {
        expect(controller.positions.length, 1);
      }
      final oldCollection = tester.widget<VirtualizedSliverCollection<Work>>(
        find.descendant(
          of: find.byKey(const ValueKey('popular-1')),
          matching: find.byType(VirtualizedSliverCollection<Work>),
        ),
      );
      final heroModes = tester.widgetList<HeroMode>(
        find.descendant(
          of: find.byType(AnimatedSwitcher).first,
          matching: find.byType(HeroMode),
        ),
      );
      expect(heroModes.where((mode) => mode.enabled).length, 1);
      expect(heroModes.where((mode) => !mode.enabled).length, 1);
      works.setDisplayMode(DisplayMode.all);
      await tester.pump();
      final current = tester
          .widget<CustomScrollView>(
            find.descendant(
              of: find.byKey(const ValueKey('all-2')),
              matching: find.byType(CustomScrollView),
            ),
          )
          .controller!;
      expect(identical(first, current), isFalse);
      expect(current.offset, 600);
      await oldCollection.onLoadMore!();
      expect(works.loadMoreCalls, 0);
      reduced.value = true;
      await tester.pump();
      final slides = tester.widgetList<SlideTransition>(
        find.descendant(
          of: find.byType(AnimatedSwitcher).first,
          matching: find.byType(SlideTransition),
        ),
      );
      expect(slides, isNotEmpty);
      for (final slide in slides) {
        expect(slide.position.value, Offset.zero);
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CustomScrollView), findsOneWidget);
      works.clearMode(DisplayMode.recommended);
      works.setDisplayMode(DisplayMode.recommended);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(works.refreshCalls, 1);
      works.setDisplayMode(DisplayMode.all);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'gallery double tap anchors its focal point and can be interrupted',
    (tester) async {
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await tester.pumpWidget(
        _app(
          const ImageGalleryScreen(
            images: [
              {'url': 'file:///missing.png'},
            ],
          ),
          reduced: reduced,
        ),
      );
      await tester.pumpAndSettle();
      final viewerFinder = find.byType(InteractiveViewer);
      final viewer = tester.widget<InteractiveViewer>(viewerFinder);
      final controller = viewer.transformationController!;
      final rect = tester.getRect(viewerFinder);
      final local = Offset(rect.width * .65, rect.height * .6);
      final point = rect.topLeft + local;
      Future<void> doubleTap() async {
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(point);
        await tester.pump();
      }

      await doubleTap();
      await tester.pump(const Duration(milliseconds: 80));
      expect(controller.value.getMaxScaleOnAxis(), inExclusiveRange(1, 2));
      expect((controller.toScene(local) - local).distance, lessThan(.01));
      final scale = controller.value.getMaxScaleOnAxis();
      await tester.pump(const Duration(milliseconds: 310));
      expect(controller.value.getMaxScaleOnAxis(), 2);
      await doubleTap();
      await tester.pump(const Duration(milliseconds: 80));
      expect(controller.value.getMaxScaleOnAxis(), lessThan(2));
      final reversing = controller.value.clone();
      await doubleTap();
      expect(controller.value, reversing);
      await tester.pump(const Duration(milliseconds: 80));
      expect(controller.value.getMaxScaleOnAxis(), greaterThan(reversing.getMaxScaleOnAxis()));
      final touch = await tester.startGesture(point);
      final stopped = controller.value.clone();
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.value, stopped);
      await touch.cancel();
      await tester.pump(const Duration(milliseconds: 350));
      await doubleTap();
      await tester.pump(const Duration(milliseconds: 45));
      reduced.value = true;
      await tester.pump();
      expect(controller.value.getMaxScaleOnAxis(), anyOf(1, 2));
      expect(scale, greaterThan(1));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('download toolbar mounts one search field and releases focus', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadTaskIdsProvider.overrideWith(
            (ref) => Stream.value(<String>[]),
          ),
        ],
        child: _app(const Scaffold(body: LocalDownloadsScreen())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byType(TextField), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode,
      same(field.focusNode),
    );
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(field.focusNode!.hasFocus, isFalse);
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'conditions reverse from current height and keep the form mounted',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            downloadSummaryProvider.overrideWith(
              (ref) => Stream.value(const DownloadTaskSummary.empty()),
            ),
          ],
          child: _app(const SearchScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byType(TextField).first;
      final fieldElement = tester.element(field);
      Future<void> add(String text) async {
        await tester.enterText(field, text);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
      }

      await add('first');
      await tester.pump(const Duration(milliseconds: 80));
      final revealFinder = find
          .ancestor(
            of: find.byType(SearchConditionChip).first,
            matching: find.byType(SizeTransition),
          )
          .first;
      final progress = tester
          .widget<SizeTransition>(revealFinder)
          .sizeFactor
          .value;
      expect(progress, inExclusiveRange(0, 1));
      await add('second');
      expect(
        tester.widget<SizeTransition>(revealFinder).sizeFactor.value,
        progress,
      );
      final chips = tester
          .widgetList<SearchConditionChip>(find.byType(SearchConditionChip))
          .toList();
      chips[0].onDeleted!();
      chips[1].onDeleted!();
      await tester.pump();
      final collapse = tester
          .widgetList<SizeTransition>(find.byType(SizeTransition))
          .first;
      expect(collapse.sizeFactor.value, progress);
      await tester.pump(const Duration(milliseconds: 60));
      expect(collapse.sizeFactor.value, lessThan(progress));
      await add('third');
      await tester.pumpAndSettle();
      expect(tester.element(field), same(fieldElement));
      expect(find.byType(SearchConditionChip), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
