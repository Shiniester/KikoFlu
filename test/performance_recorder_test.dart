import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/performance/performance_recorder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final recorder = PerformanceRecorder.instance;

  setUp(() {
    recorder
      ..start(force: true)
      ..resetRun();
  });

  test('attributes delayed timing batches by frame timestamp', () {
    recorder
      ..setRefreshRate(90)
      ..debugSetFrameTimestamp(100)
      ..beginScenario('first')
      ..debugRecordFrameTiming(
        timestampUs: 101,
        uiMs: 2,
        rasterMs: 3,
        totalSpanMs: 80,
      )
      ..debugSetFrameTimestamp(200);
    recorder.endScenario();

    // This callback arrives after endScenario, but its frame was produced in
    // the first window. It must not be charged to the next scenario.
    recorder.debugRecordFrameTiming(
      timestampUs: 150,
      uiMs: 4,
      rasterMs: 5,
      totalSpanMs: 90,
    );
    recorder
      ..debugSetFrameTimestamp(300)
      ..beginScenario('second')
      ..debugRecordFrameTiming(
        timestampUs: 301,
        uiMs: 6,
        rasterMs: 7,
        totalSpanMs: 100,
      )
      ..debugSetFrameTimestamp(400);
    recorder.endScenario();

    final run = recorder.createRun(run: 1);
    final metrics = (run['metrics']! as Map).cast<String, num>();
    expect(metrics['firstFrameCount'], 2);
    expect(metrics['secondFrameCount'], 1);
    expect(metrics['firstTimingBatches'], 2);
    expect(metrics['secondTimingBatches'], 1);
    expect(metrics['firstUiP95Ms'], 4);
    expect(metrics['secondRasterP95Ms'], 7);
  });

  test('uses UI/raster work for budget and keeps total span separate', () {
    recorder
      ..setRefreshRate(90)
      ..debugSetFrameTimestamp(100)
      ..beginScenario('render')
      ..debugRecordFrameTiming(
        timestampUs: 101,
        uiMs: 2,
        rasterMs: 3,
        totalSpanMs: 80,
      )
      ..debugRecordFrameTiming(
        timestampUs: 102,
        uiMs: 12,
        rasterMs: 4,
        totalSpanMs: 100,
      )
      ..debugSetFrameTimestamp(200);
    recorder.endScenario();

    final run = recorder.createRun(run: 1);
    final metrics = (run['metrics']! as Map).cast<String, num>();
    expect(metrics['renderFrameBudgetMs'], closeTo(1000 / 90, 0.0001));
    expect(metrics['renderJankyFrames'], 1);
    expect(metrics['renderFrameP95Ms'], 12);
    expect(metrics['renderTotalSpanP95Ms'], 100);
  });
}
