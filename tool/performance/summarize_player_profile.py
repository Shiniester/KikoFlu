"""Summarize real-player runs without including source paths or device identifiers."""

import argparse
import json
import math
from pathlib import Path
import statistics


SCENES = ['expandCold', 'expandCollapse', 'dragRebound', 'dragHandoff',
          'pageSwitch', 'lyricFollow', 'lyricScroll']


def percentile(values, fraction):
    return sorted(values)[math.ceil((len(values) - 1) * fraction)]


def distribution(values):
    return dict(count=len(values), median=round(statistics.median(values), 3),
                p95=round(percentile(values, .95), 3))


def summarize(root, label):
    reports = [json.loads(path.read_text(encoding='utf-8'))
               for path in sorted(root.glob(label + '_*.json'))
               if not path.name.endswith('_environment.json')]
    if not reports:
        raise ValueError(f'No reports for {label}')
    metrics = [report['run']['metrics'] for report in reports]
    result = dict(runs=len(reports), ui={}, outgoing={}, requests={})
    for scene in SCENES:
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
    args = parser.parse_args()
    result = {label: summarize(args.reports, label) for label in args.labels}
    encoded = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded + '\n', encoding='utf-8')
    else:
        print(encoded)


if __name__ == '__main__':
    main()
