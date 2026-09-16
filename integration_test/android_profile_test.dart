import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/main.dart' as kikoflu_app;
import 'package:kikoeru_flutter/src/models/download_task.dart';
import 'package:kikoeru_flutter/src/performance/performance_fixture_manifest.dart';
import 'package:kikoeru_flutter/src/performance/performance_recorder.dart';
import 'package:kikoeru_flutter/src/performance/performance_scenario_adapter.dart';
import 'package:kikoeru_flutter/src/widgets/virtualized_sliver_collection.dart';

final Stopwatch _processStartupStopwatch = Stopwatch();

void main() {
  _processStartupStopwatch.start();
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('fixed Android Profile performance scenario', (tester) async {
    const controlPath = String.fromEnvironment(
      'KIKOFLU_PERF_CONTROL_PATH',
      defaultValue:
          '/sdcard/Android/data/com.meteor.kikoeruflutter/files/'
          'performance_fixtures/control.json',
    );
    final control = await _readObject(controlPath);
    final runNumber = (control['run'] as num).toInt();
    final manifestPath = control['fixtureManifestPath']! as String;
    final expectedFixtureHash = control['fixtureHash']! as String;
    final thermalStatus = control['thermalStatus']!.toString();
    final batteryPercent = (control['batteryPercent'] as num).toInt();
    final batteryTemperatureTenthsCelsius =
        (control['batteryTemperatureTenthsCelsius'] as num).toInt();
    final skipDownloads = control['skipDownloads'] == true;

    final adapter = createPerformanceScenarioAdapter();
    final recorder = PerformanceRecorder.instance
      ..start(force: true)
      ..resetRun();
    final harnessKey = GlobalKey<_ProfileHarnessState>();

    // Start the real application before loading the large deterministic
    // fixture. This keeps cold-start timing independent from fixture I/O.
    kikoflu_app.main(const []);
    await _waitForFirstInteractive(tester, recorder);
    recorder.recordMetric(
      'coldStartMs',
      _processStartupStopwatch.elapsedMicroseconds / 1000,
    );
    await adapter.waitForBackgroundWork();

    expect(
      manifestPath,
      isNotEmpty,
      reason: 'KIKOFLU_PERF_FIXTURE_MANIFEST is required',
    );
    final manifestFile = File(manifestPath);
    expect(await manifestFile.exists(), isTrue);
    final manifest = await PerformanceFixtureManifest.read(manifestFile);
    expect(
      manifest.contentHash,
      expectedFixtureHash,
      reason: 'The device fixture differs from the host fixture manifest',
    );

    final works = await _readObjectList(
      manifest.resolvePath(manifestPath, manifest.worksPath),
    );
    expect(works, hasLength(manifest.works));
    if (!skipDownloads) {
      final tasks = (await _readObjectList(
        manifest.resolvePath(manifestPath, manifest.downloadTasksPath),
      )).map((json) => DownloadTask.fromJson(json)).toList(growable: false);
      expect(tasks, hasLength(manifest.downloadTasks));
      adapter.injectDownloadTasks(tasks);
    }

    final outputRoot = Directory(
      manifest.resolvePath(manifestPath, 'run_output/run_$runNumber'),
    );
    if (await outputRoot.exists()) {
      await outputRoot.delete(recursive: true);
    }
    await outputRoot.create(recursive: true);
    final artworkData = await rootBundle.load(
      'assets/icons/app_icon_opaque.png',
    );
    final artworkFile = File(
      '${outputRoot.path}${Platform.pathSeparator}player_route_artwork.png',
    );
    await artworkFile.writeAsBytes(
      artworkData.buffer.asUint8List(
        artworkData.offsetInBytes,
        artworkData.lengthInBytes,
      ),
      flush: true,
    );

    try {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            theme: ThemeData(platform: TargetPlatform.android),
            home: _ProfileHarness(
              key: harnessKey,
              adapter: adapter,
              works: works,
              artworkFilePath: artworkFile.path,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      recorder.beginScenario('home');
      final homeScrollable = find.descendant(
        of: find.byKey(const ValueKey('profile-home')),
        matching: find.byType(Scrollable),
      );
      expect(homeScrollable, findsWidgets);
      for (var index = 0; index < 12; index++) {
        await tester.fling(homeScrollable.first, const Offset(0, -900), 1800);
        await tester.pump(const Duration(milliseconds: 250));
      }
      recorder.endScenario();

      if (!skipDownloads) {
        harnessKey.currentState!.selectTab(1);
        await tester.pump(const Duration(milliseconds: 500));
        adapter.resetDownloadCounters();
        final progressLatencies = <double>[];
        for (var tick = 0; tick < 20; tick++) {
          final stopwatch = Stopwatch()..start();
          adapter.advanceActiveDownloads(tick + 1);
          await tester.pump(const Duration(milliseconds: 500));
          stopwatch.stop();
          progressLatencies.add(stopwatch.elapsedMicroseconds / 1000);
        }
        final downloadCounters = adapter.readDownloadCounters();
        recorder
          ..recordMetric('downloadListBuilds', downloadCounters.taskRowBuilds)
          ..recordMetric(
            'downloadTemporaryAllocations',
            downloadCounters.temporaryListAllocations,
          )
          ..recordMetric(
            'downloadProgressLatencyMs',
            progressLatencies.reduce(
              (left, right) => left > right ? left : right,
            ),
          );
      }

      harnessKey.currentState!.selectTab(2);
      await tester.pump(const Duration(milliseconds: 500));
      await _measureAutomaticPlayerRoutes(tester, recorder);
      await _measureInteractivePlayerRoutes(tester, recorder);

      final subtitleRoot = manifest.resolvePath(
        manifestPath,
        manifest.subtitleRootPath,
      );
      final scanMeasurement = await _measurePeakPss(
        () => adapter.scanSubtitleDirectory(subtitleRoot),
      );
      expect(scanMeasurement.value, hasLength(manifest.localRecords));
      recorder
        ..recordMetric(
          'scanDurationMs',
          scanMeasurement.stopwatch.elapsedMicroseconds / 1000,
        )
        ..recordMetric('scanPeakPssMb', scanMeasurement.peakPssMb)
        ..recordMetric('scanPeakPssDeltaMb', scanMeasurement.peakPssDeltaMb);

      final zipMeasurement = await _measurePeakPss(
        () => adapter.importSubtitleArchive(
          sourcePath: manifest.resolvePath(manifestPath, manifest.zipPath),
          targetPath: outputRoot.path,
        ),
      );
      expect(zipMeasurement.value.success, isTrue);
      recorder
        ..recordMetric(
          'zipImportDurationMs',
          zipMeasurement.stopwatch.elapsedMicroseconds / 1000,
        )
        ..recordMetric('zipPeakPssMb', zipMeasurement.peakPssMb)
        ..recordMetric('zipPeakPssDeltaMb', zipMeasurement.peakPssDeltaMb);
    } finally {
      if (!skipDownloads) adapter.clearDownloadTasks();
      if (await outputRoot.exists()) {
        await outputRoot.delete(recursive: true);
      }
    }

    binding.reportData = {
      'schemaVersion': 3,
      'scenario': skipDownloads
          ? 'kikoflu-android-profile-v3-no-downloads'
          : 'kikoflu-android-profile-v3',
      'scenarioAdapterVersion': performanceScenarioAdapterVersion,
      'adapterImplementation': adapter.implementation,
      'fixture': manifest.toReportJson(),
      'run': recorder.createRun(
        run: runNumber,
        metadata: {
          'thermalStatus': thermalStatus,
          'batteryPercent': batteryPercent,
          'batteryTemperatureTenthsCelsius': batteryTemperatureTenthsCelsius,
        },
      ),
    };
  });
}

class _ProfileHarness extends StatefulWidget {
  const _ProfileHarness({
    super.key,
    required this.adapter,
    required this.works,
    required this.artworkFilePath,
  });

  final PerformanceScenarioAdapter adapter;
  final List<Map<String, dynamic>> works;
  final String artworkFilePath;

  @override
  State<_ProfileHarness> createState() => _ProfileHarnessState();
}

class _ProfileHarnessState extends State<_ProfileHarness> {
  final Set<int> _visitedTabs = {0};
  int _selectedTab = 0;

  void selectTab(int index) {
    setState(() {
      _selectedTab = index;
      _visitedTabs.add(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: widget.adapter.buildTabHost(
        index: _selectedTab,
        visitedIndices: _visitedTabs,
        children: [
          _ProfileHome(works: widget.works),
          widget.adapter.buildDownloads(),
          widget.adapter.buildPlayer(artworkFilePath: widget.artworkFilePath),
        ],
      ),
    );
  }
}

class _ProfileHome extends StatelessWidget {
  const _ProfileHome({required this.works});

  final List<Map<String, dynamic>> works;

  @override
  Widget build(BuildContext context) {
    return VirtualizedSliverCollection<Map<String, dynamic>>(
      key: const ValueKey('profile-home'),
      items: works,
      itemId: (item) => item['id']!,
      layout: VirtualizedCollectionLayout.grid,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.1,
      ),
      showEndIndicator: false,
      itemBuilder: (context, item, index) => Card(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const FlutterLogo(size: 72),
            Text(item['source_id']?.toString() ?? 'RJ${item['id']}'),
            Text(item['title']?.toString() ?? 'Performance Work $index'),
          ],
        ),
      ),
    );
  }
}

const _profileRouteCycles = 5;
const _minimumRouteFrameSamples = 200;

Future<void> _measureAutomaticPlayerRoutes(
  WidgetTester tester,
  PerformanceRecorder recorder,
) async {
  const scenario = 'playerRouteAutomatic';
  recorder.beginScenario(scenario);
  for (var cycle = 0; cycle < _profileRouteCycles; cycle++) {
    await tester.tap(find.byKey(const ValueKey('mini-player-artwork-frame')));
    await _pumpRouteAnimation(tester);
    expect(find.byKey(const ValueKey('compact-player-layout')), findsOneWidget);

    Navigator.of(
      tester.element(find.byKey(const ValueKey('compact-player-layout'))),
    ).pop();
    await _pumpRouteAnimation(tester);
    expect(
      find.byKey(const ValueKey('mini-player-upward-launcher')),
      findsOneWidget,
    );
  }
  await _endMeasuredScenario(tester, recorder, scenario);
}

Future<void> _measureInteractivePlayerRoutes(
  WidgetTester tester,
  PerformanceRecorder recorder,
) async {
  const scenario = 'playerRouteInteractive';
  recorder.beginScenario(scenario);
  for (var cycle = 0; cycle < _profileRouteCycles; cycle++) {
    final launcher = find.byKey(const ValueKey('mini-player-upward-launcher'));

    final cancelledOpen = await tester.startGesture(tester.getCenter(launcher));
    for (var step = 0; step < 6; step++) {
      await cancelledOpen.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await cancelledOpen.cancel();
    await _pumpRouteAnimation(tester);
    expect(find.byKey(const ValueKey('compact-player-layout')), findsNothing);

    final open = await tester.startGesture(tester.getCenter(launcher));
    for (var step = 0; step < 14; step++) {
      await open.moveBy(const Offset(0, -16));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await open.up();
    await _pumpRouteAnimation(tester);
    expect(find.byKey(const ValueKey('compact-player-layout')), findsOneWidget);

    final header = find.byKey(const ValueKey('compact-header-dismiss-surface'));
    final cancelledDismiss = await tester.startGesture(
      tester.getCenter(header),
    );
    for (var step = 0; step < 6; step++) {
      await cancelledDismiss.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await cancelledDismiss.up();
    await _pumpRouteAnimation(tester);
    expect(find.byKey(const ValueKey('compact-player-layout')), findsOneWidget);

    final dismiss = await tester.startGesture(tester.getCenter(header));
    for (var step = 0; step < 14; step++) {
      await dismiss.moveBy(const Offset(0, 16));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await dismiss.up();
    await _pumpRouteAnimation(tester);
    expect(
      find.byKey(const ValueKey('mini-player-upward-launcher')),
      findsOneWidget,
    );
  }
  await _endMeasuredScenario(tester, recorder, scenario);
}

Future<void> _pumpRouteAnimation(WidgetTester tester) async {
  for (var frame = 0; frame < 32; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _endMeasuredScenario(
  WidgetTester tester,
  PerformanceRecorder recorder,
  String scenario,
) async {
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump();
  await Future<void>.delayed(Duration.zero);
  final metrics = recorder.endScenario();
  expect(
    metrics['${scenario}FrameCount'],
    greaterThanOrEqualTo(_minimumRouteFrameSamples),
    reason: '$scenario did not capture enough FrameTiming samples',
  );
}

Future<List<Map<String, dynamic>>> _readObjectList(String path) async {
  final decoded = jsonDecode(await File(path).readAsString());
  if (decoded is! List) throw FormatException('$path is not a JSON list');
  return decoded
      .map((value) => Map<String, dynamic>.from(value as Map))
      .toList(growable: false);
}

Future<Map<String, dynamic>> _readObject(String path) async {
  final decoded = jsonDecode(await File(path).readAsString());
  if (decoded is! Map) throw FormatException('$path is not a JSON object');
  return Map<String, dynamic>.from(decoded);
}

Future<
  ({T value, Stopwatch stopwatch, double peakPssMb, double peakPssDeltaMb})
>
_measurePeakPss<T>(Future<T> Function() operation) async {
  final startingPss = _currentPssBytes();
  var peakPss = startingPss;
  // PSS collection walks process page tables. Sampling a 1 GB legacy ZIP
  // import every 50 ms materially perturbs low-memory devices and can trigger
  // swap storms, so use a still-subsecond interval that captures multi-second
  // operation peaks without dominating the operation being measured.
  final timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
    final current = _currentPssBytes();
    if (current > peakPss) peakPss = current;
  });
  final stopwatch = Stopwatch()..start();
  try {
    final value = await operation();
    final finalPss = _currentPssBytes();
    if (finalPss > peakPss) peakPss = finalPss;
    stopwatch.stop();
    return (
      value: value,
      stopwatch: stopwatch,
      peakPssMb: peakPss / (1024 * 1024),
      peakPssDeltaMb:
          (peakPss > startingPss ? peakPss - startingPss : 0) / (1024 * 1024),
    );
  } finally {
    timer.cancel();
  }
}

int _currentPssBytes() {
  for (final path in const ['/proc/self/smaps_rollup', '/proc/self/smaps']) {
    try {
      var pssKilobytes = 0;
      for (final line in File(path).readAsLinesSync()) {
        if (!line.startsWith('Pss:')) continue;
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length >= 2) {
          pssKilobytes += int.tryParse(fields[1]) ?? 0;
        }
      }
      if (pssKilobytes > 0) return pssKilobytes * 1024;
    } on FileSystemException {
      // Continue to the detailed map, then the portable RSS fallback.
    }
  }
  return ProcessInfo.currentRss;
}

Future<void> _waitForFirstInteractive(
  WidgetTester tester,
  PerformanceRecorder recorder,
) async {
  final timeout = Stopwatch()..start();
  while (recorder.metric('firstInteractiveMs') == null &&
      timeout.elapsed < const Duration(seconds: 90)) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(
    recorder.metric('firstInteractiveMs'),
    isNotNull,
    reason: 'the real KikoFlu bootstrap did not become interactive in 90 s',
  );
}
