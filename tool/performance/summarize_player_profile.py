"""Summarize real-player runs without including source paths or device identifiers."""

import argparse
import json
import math
from pathlib import Path
import statistics


SCENES = ['expandCold', 'expandCollapse', 'dragRebound', 'dragHandoff',
          'pageSwitch', 'queuePageSwitch', 'queueEdgeHandoff',
          'queueContinuousHandoff', 'lyricFollow', 'lyricScroll',
          'rapidTrackPresentation', 'galleryDoubleTap']
HORIZONTAL_SCENES = ['pageDrag', 'pageRelease', 'pageSwitch']


def percentile(values, fraction):
    return sorted(values)[math.ceil((len(values) - 1) * fraction)]


def distribution(values):
    return dict(count=len(values), median=round(statistics.median(values), 3),
                p95=round(percentile(values, .95), 3))


def summarize(root, label, start, rounds, horizontal_only=False):
    reports = []
    for number in range(start, start + rounds):
        path = root / f'{label}_{number}.json'
        report = json.loads(path.read_text(encoding='utf-8'))
        if (report['control']['label'] != label or
                report['control']['run'] != number or report['run']['run'] != number):
            raise ValueError(f'Report identity does not match {path.name}')
        if any(check['case'] == 'harnessFailure' for check in report['checks']):
            raise ValueError(f'Harness failed in {path.name}')
        metric = report['run']['metrics']
        if report['control']['ui']:
            if horizontal_only or report['control'].get('horizontalOnly'):
                windows = report['run']['frameSamples']
                for phase in ['pageDrag', 'pageRelease']:
                    for swipe in range(report['control']['cycles'] * 4):
                        if not windows.get(f'{phase}{swipe}'):
                            raise ValueError(f'Missing {phase}{swipe} frames in {path.name}')
                for scene in HORIZONTAL_SCENES:
                    prefix = 'page' if scene == 'pageSwitch' else scene
                    frames = [frame for name, samples in windows.items()
                              if name.startswith(prefix) for frame in samples]
                    budget = metric['frameBudgetMs']
                    metric.update({
                        scene + 'UiP95Ms': percentile([frame[0] for frame in frames], .95),
                        scene + 'RasterP95Ms': percentile([frame[1] for frame in frames], .95),
                        scene + 'FrameP95Ms': percentile([max(frame) for frame in frames], .95),
                        scene + 'FrameBudgetMs': budget,
                        scene + 'JankyFrames': sum(max(frame) > budget for frame in frames),
                        scene + 'FrameCount': len(frames),
                    })
                required_scenes = HORIZONTAL_SCENES
            else:
                required_scenes = [scene for scene in SCENES if scene != 'queueContinuousHandoff']
            if report['control'].get('continuousHandoff'):
                required_scenes.append('queueContinuousHandoff')
                checks = [check for check in report['checks']
                          if check['case'] == 'queueContinuousHandoff']
                if len(checks) != 1 or checks[0].get('passed') is not True:
                    raise ValueError(f'Continuous handoff check is missing or failed in {path.name}')
            for scene in required_scenes:
                for suffix in ['UiP95Ms', 'RasterP95Ms', 'FrameP95Ms', 'FrameBudgetMs',
                               'JankyFrames', 'FrameCount']:
                    value = metric.get(scene + suffix)
                    if value is None or not math.isfinite(value) or value < 0:
                        raise ValueError(f'Missing or invalid {scene + suffix} in {path.name}')
                if metric[scene + 'FrameCount'] == 0 or metric[scene + 'FrameBudgetMs'] == 0:
                    raise ValueError(f'No measured frames or frame budget for {scene} in {path.name}')
        reports.append(report)
    metrics = [report['run']['metrics'] for report in reports]
    result = dict(runs=len(reports), ui={}, outgoing={}, requests={})
    for scene in SCENES + ['pageDrag', 'pageRelease']:
        if any(scene + 'FrameP95Ms' not in metric for metric in metrics):
            continue
        summary = {
            suffix: round(statistics.median([metric[scene + suffix] for metric in metrics]), 3)
            for suffix in ['UiP95Ms', 'RasterP95Ms', 'FrameP95Ms', 'FrameBudgetMs']
        }
        summary['worstRunFrameP95Ms'] = max(metric[scene + 'FrameP95Ms'] for metric in metrics)
        summary['jankPercent'] = round(
            100 * sum(metric[scene + 'JankyFrames'] for metric in metrics) /
            sum(metric[scene + 'FrameCount'] for metric in metrics), 3,
        )
        result['ui'][scene] = summary
    outgoing, timings = {}, {}
    for report in reports:
        for sample in report['switchSamples']:
            outgoing.setdefault(sample['from'], []).append(sample['elapsedMs'])
        for timing in report['run'].get('playbackTimings', []):
            if not timing['incomplete']:
                timings.setdefault(timing['trackId'], []).append(timing)
    result['outgoing'] = {track: distribution(values) for track, values in outgoing.items()}
    for track, samples in timings.items():
        result['requests'][track] = {}
        for phase in ['sourcePreparationMs', 'setFilePathMs', 'requestToReadyMs',
                      'requestToFirstPositionMs']:
            values = [sample[phase] for sample in samples if sample.get(phase) is not None]
            if values:
                result['requests'][track][phase] = distribution(values)
    result['checks'] = [dict(run=report['run']['run'], checks=report['checks']) for report in reports]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('labels', nargs='+')
    parser.add_argument('--reports', type=Path, default=Path('build/player_performance/reports'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--start', type=int, default=1)
    parser.add_argument('--rounds', type=int, default=5)
    parser.add_argument('--horizontal-only', action='store_true')
    args = parser.parse_args()
    if args.start < 1 or args.rounds < 1:
        parser.error('--start and --rounds must be positive')
    result = {label: summarize(args.reports, label, args.start, args.rounds,
                               horizontal_only=args.horizontal_only)
              for label in args.labels}
    encoded = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded + '\n', encoding='utf-8')
    else:
        print(encoded)


if __name__ == '__main__':
    main()
