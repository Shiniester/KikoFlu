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
LYRIC_OPEN_CLOSE_SCENES = [f'lyricOpenClose{cycle}' for cycle in range(4)]
LYRIC_FRAME_SCENES = ['lyricFollow', 'lyricJump', 'lyricScroll',
                      *LYRIC_OPEN_CLOSE_SCENES]
LYRIC_SETTINGS = {
    'lyricSpringPreset': 'default',
    'textScale': 1.0,
    'reducedMotion': False,
}
LYRIC_HIDDEN_HOST = 'audioDetails'
LYRIC_FRAME_SCHEDULING = 'frameworkRequests'


def label_role(label):
    role = label.casefold().replace('-', '_').split('_', 1)[0]
    return role if role in ['baseline', 'candidate'] else None


def percentile(values, fraction):
    return sorted(values)[math.ceil((len(values) - 1) * fraction)]


def distribution(values):
    return dict(count=len(values), median=round(statistics.median(values), 3),
                p95=round(percentile(values, .95), 3))


def validate_lyric_open_close(report, path):
    control = report['control']
    run = report['run']
    metrics = run['metrics']
    windows = run.get('frameSamples', {})
    cycles = control.get('cycles')
    if (not isinstance(cycles, int) or isinstance(cycles, bool) or
            cycles != len(LYRIC_OPEN_CLOSE_SCENES)):
        raise ValueError(f'Invalid subtitle open-close cycle count in {path.name}')
    names = LYRIC_OPEN_CLOSE_SCENES
    actual_names = sorted(name for name in windows if name.startswith('lyricOpenClose'))
    if actual_names != names:
        raise ValueError(f'Missing subtitle open-close frame samples in {path.name}')

    for name in names:
        budget = metrics.get(name + 'FrameBudgetMs')
        if (not isinstance(budget, (int, float)) or not math.isfinite(budget) or
                budget <= 0):
            raise ValueError(f'Missing subtitle open-close frame budget in {path.name}')
        samples = windows[name]
        if not samples:
            raise ValueError(f'No measured frames for {name} in {path.name}')
        for frame in samples:
            if (not isinstance(frame, list) or len(frame) != 2 or
                    any(not isinstance(value, (int, float)) or
                        isinstance(value, bool) or not math.isfinite(value) or value < 0
                        for value in frame)):
                raise ValueError(f'Invalid frame sample for {name} in {path.name}')


def validate_closed_idle(report, path, candidate):
    checks = [check for check in report['checks']
              if check['case'] == 'lyricClosedIdle']
    cycles = report['control']['cycles']
    if len(checks) != cycles:
        raise ValueError(f'Closed subtitle idle checks are missing in {path.name}')
    by_cycle = {}
    for check in checks:
        cycle = check.get('cycle')
        frame_count = check.get('frameCount')
        if (not isinstance(cycle, int) or isinstance(cycle, bool) or
                cycle in by_cycle):
            raise ValueError(f'Invalid closed subtitle idle cycle in {path.name}')
        if (not isinstance(frame_count, (int, float)) or isinstance(frame_count, bool) or
                not math.isfinite(frame_count) or frame_count < 0):
            raise ValueError(f'Missing closed subtitle idle frame count in {path.name}')
        if check.get('windowMs') != 1000 or not isinstance(check.get('passed'), bool):
            raise ValueError(f'Invalid closed subtitle idle window in {path.name}')
        by_cycle[cycle] = check
    if set(by_cycle) != set(range(cycles)):
        raise ValueError(f'Closed subtitle idle cycles do not match in {path.name}')
    if candidate and any(
        check['passed'] is not True or check['frameCount'] != 0
        for check in by_cycle.values()
    ):
        raise ValueError(f'Closed subtitle page kept rendering in {path.name}')


def summarize(root, label, start, rounds, horizontal_only=False, lyrics_only=False):
    candidate = label_role(label) == 'candidate'
    reports = []
    settings = None
    for number in range(start, start + rounds):
        path = root / f'{label}_{number}.json'
        report = json.loads(path.read_text(encoding='utf-8'))
        if (report['control']['label'] != label or
                report['control']['run'] != number or report['run']['run'] != number):
            raise ValueError(f'Report identity does not match {path.name}')
        if any(check['case'] == 'harnessFailure' for check in report['checks']):
            raise ValueError(f'Harness failed in {path.name}')
        if lyrics_only:
            if report['control'].get('lyricsOnly') is not True:
                raise ValueError(f'Non-lyrics-only run in {path.name}')
            if not report['control'].get('sourceSha'):
                raise ValueError(f'Missing source SHA in {path.name}')
            control_settings = {
                key: report['control'].get(key) for key in LYRIC_SETTINGS
            }
            run_metadata = report['run'].get('metadata')
            if not isinstance(run_metadata, dict):
                raise ValueError(f'Missing runtime subtitle settings in {path.name}')
            if run_metadata.get('lyricHiddenHost') != LYRIC_HIDDEN_HOST:
                raise ValueError(
                    f'Runtime subtitle host must be {LYRIC_HIDDEN_HOST} in {path.name}'
                )
            if run_metadata.get('frameScheduling') != LYRIC_FRAME_SCHEDULING:
                raise ValueError(
                    f'Runtime frame scheduling must be '
                    f'{LYRIC_FRAME_SCHEDULING} in {path.name}'
                )
            actual_settings = {
                key: run_metadata.get(key) for key in LYRIC_SETTINGS
            }
            if control_settings != LYRIC_SETTINGS:
                raise ValueError(f'Unexpected subtitle settings in {path.name}')
            if actual_settings != control_settings:
                raise ValueError(f'Runtime subtitle settings do not match control in {path.name}')
            if settings is not None and actual_settings != settings:
                raise ValueError(f'Subtitle settings changed between runs for {label}')
            settings = actual_settings
            validate_lyric_open_close(report, path)
            validate_closed_idle(report, path, candidate)
            hidden_checks = [check for check in report['checks']
                             if check['case'] == 'lyricHiddenIdle']
            if len(hidden_checks) != 1:
                raise ValueError(f'Hidden subtitle idle check is missing in {path.name}')
            if candidate and hidden_checks[0].get('passed') is not True:
                raise ValueError(f'Hidden subtitle page kept rendering in {path.name}')
        metric = report['run']['metrics']
        if report['control']['ui']:
            if lyrics_only:
                required_scenes = LYRIC_FRAME_SCENES
            elif horizontal_only or report['control'].get('horizontalOnly'):
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
    source_shas = {report['control'].get('sourceSha') for report in reports}
    if lyrics_only and (None in source_shas or len(source_shas) != 1):
        raise ValueError(f'Runs for {label} used different source SHAs')
    result = dict(runs=len(reports), ui={}) if lyrics_only else dict(
        runs=len(reports), ui={}, outgoing={}, requests={},
    )
    if lyrics_only:
        result['sourceSha'] = next(iter(source_shas))
        result['settings'] = settings
        result['frameBudgets'] = {
            scene: [metric[scene + 'FrameBudgetMs'] for metric in metrics]
            for scene in LYRIC_FRAME_SCENES
        }
    summary_scenes = LYRIC_FRAME_SCENES if lyrics_only else SCENES + ['pageDrag', 'pageRelease']
    for scene in summary_scenes:
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
    if not lyrics_only:
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
    parser.add_argument('--lyrics-only', action='store_true')
    args = parser.parse_args()
    if args.start < 1 or args.rounds < 1:
        parser.error('--start and --rounds must be positive')
    comparison_labels = {}
    if args.lyrics_only:
        if len(args.labels) != 2:
            parser.error('--lyrics-only requires one baseline and one candidate label')
        comparison_labels = {label_role(label): label for label in args.labels}
        if set(comparison_labels) != {'baseline', 'candidate'}:
            parser.error('--lyrics-only labels must start with baseline and candidate')
    result = {label: summarize(args.reports, label, args.start, args.rounds,
                               horizontal_only=args.horizontal_only,
                               lyrics_only=args.lyrics_only)
              for label in args.labels}
    if args.lyrics_only:
        baseline = result[comparison_labels['baseline']]
        candidate = result[comparison_labels['candidate']]
        if baseline['sourceSha'] == candidate['sourceSha']:
            raise ValueError('Baseline and candidate source SHAs must differ')
        if baseline['settings'] != candidate['settings']:
            raise ValueError('Baseline and candidate subtitle settings differ')
        for scene in LYRIC_FRAME_SCENES:
            for run, (baseline_budget, candidate_budget) in enumerate(zip(
                baseline['frameBudgets'][scene], candidate['frameBudgets'][scene],
            ), start=args.start):
                if abs(baseline_budget - candidate_budget) > 0.001:
                    raise ValueError(
                        f'Display frame budget changed for {scene} in run {run}'
                    )
    encoded = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded + '\n', encoding='utf-8')
    else:
        print(encoded)


if __name__ == '__main__':
    main()
