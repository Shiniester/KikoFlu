"""Regression tests for the lyrics-only profile comparison CLI."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SUMMARY_SCRIPT = Path(__file__).with_name('summarize_player_profile.py')
LABELS = ('baseline_lyrics', 'candidate_lyrics')
SCENES = ('lyricFollow', 'lyricJump', 'lyricScroll', 'lyricOpenClose')
SETTINGS = {
    'lyricSpringPreset': 'default',
    'textScale': 1.0,
    'reducedMotion': False,
}


def write_report(root, label, run, budget=16.667, metadata=None, checks=None):
    metrics = {}
    for scene in SCENES[:-1]:
        metrics.update({
            scene + 'UiP95Ms': 5.0,
            scene + 'RasterP95Ms': 4.0,
            scene + 'FrameP95Ms': 5.0,
            scene + 'FrameBudgetMs': budget,
            scene + 'JankyFrames': 0,
            scene + 'FrameCount': 30,
        })
    for cycle in range(4):
        scene = f'lyricOpenClose{cycle}'
        metrics.update({
            scene + 'UiP95Ms': 5.0,
            scene + 'RasterP95Ms': 4.0,
            scene + 'FrameP95Ms': 5.0,
            scene + 'FrameBudgetMs': budget,
            scene + 'JankyFrames': 0,
            scene + 'FrameCount': 3,
        })
    closed_idle_checks = [
        {
            'case': 'lyricClosedIdle',
            'cycle': cycle,
            'frameCount': 0,
            'windowMs': 1000,
            'passed': True,
        }
        for cycle in range(4)
    ]
    frame_samples = {
        f'lyricOpenClose{cycle}': [[5.0, 4.0] for _ in range(3)]
        for cycle in range(4)
    }
    report = {
        'control': {
            'label': label,
            'run': run,
            'package': 'com.meteor.kikoeruflutter.profile',
            'sourceSha': 'a' * 40 if label.startswith('baseline') else 'b' * 40,
            'cycles': 4,
            'ui': True,
            'lyricsOnly': True,
            **SETTINGS,
        },
        'run': {
            'run': run,
            'metrics': metrics,
            'metadata': metadata if metadata is not None else SETTINGS,
            'frameSamples': frame_samples,
        },
        'switchSamples': [],
        'checks': checks if checks is not None else [
            {'case': 'lyricHiddenIdle', 'passed': True, 'frameCount': 0},
        ] + closed_idle_checks,
    }
    root.mkdir(parents=True, exist_ok=True)
    (root / f'{label}_{run}.json').write_text(
        json.dumps(report), encoding='utf-8',
    )
    return report


def run_summary(reports, rounds=1):
    return subprocess.run(
        [
            sys.executable,
            str(SUMMARY_SCRIPT),
            *LABELS,
            '--reports',
            str(reports),
            '--rounds',
            str(rounds),
            '--lyrics-only',
        ],
        capture_output=True,
        encoding='utf-8',
        check=False,
    )


class SummarizePlayerProfileTests(unittest.TestCase):
    def test_suffix_labels_and_matching_report_summarize(self):
        with tempfile.TemporaryDirectory() as temporary:
            reports = Path(temporary)
            for label in LABELS:
                write_report(reports, label, 1)

            result = run_summary(reports)

            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads(result.stdout)
            self.assertEqual(summary['baseline_lyrics']['settings'], SETTINGS)
            self.assertEqual(
                summary['candidate_lyrics']['ui']['lyricFollow']['FrameBudgetMs'],
                16.667,
            )

    def test_mixed_per_round_budgets_fail_even_when_medians_match(self):
        with tempfile.TemporaryDirectory() as temporary:
            reports = Path(temporary)
            for label in LABELS:
                for run in range(1, 4):
                    budget = 8.333 if label.startswith('baseline') else (
                        16.667 if run == 1 else 8.333
                    )
                    write_report(reports, label, run, budget=budget)

            result = run_summary(reports, rounds=3)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Display frame budget changed for lyricFollow in run 1',
                          result.stderr)

    def test_missing_scene_metric_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            reports = Path(temporary)
            write_report(reports, LABELS[0], 1)
            candidate = write_report(reports, LABELS[1], 1)
            del candidate['run']['metrics']['lyricJumpUiP95Ms']
            (reports / f'{LABELS[1]}_1.json').write_text(
                json.dumps(candidate), encoding='utf-8',
            )

            result = run_summary(reports)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Missing or invalid lyricJumpUiP95Ms', result.stderr)

    def test_runtime_settings_must_match_control(self):
        with tempfile.TemporaryDirectory() as temporary:
            reports = Path(temporary)
            write_report(reports, LABELS[0], 1)
            actual = dict(SETTINGS, textScale=1.15)
            write_report(reports, LABELS[1], 1, metadata=actual)

            result = run_summary(reports)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Runtime subtitle settings do not match control',
                          result.stderr)

    def test_candidate_closed_idle_frames_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            reports = Path(temporary)
            write_report(reports, LABELS[0], 1)
            checks = [
                {'case': 'lyricHiddenIdle', 'passed': True, 'frameCount': 0},
                *[
                    {
                        'case': 'lyricClosedIdle',
                        'cycle': cycle,
                        'frameCount': int(cycle == 2),
                        'windowMs': 1000,
                        'passed': cycle != 2,
                    }
                    for cycle in range(4)
                ],
            ]
            write_report(reports, LABELS[1], 1, checks=checks)

            result = run_summary(reports)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Closed subtitle page kept rendering', result.stderr)

    def test_harness_failure_report_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            reports = Path(temporary)
            write_report(reports, LABELS[0], 1)
            write_report(
                reports,
                LABELS[1],
                1,
                checks=[{'case': 'harnessFailure', 'error': 'bad control file'}],
            )

            result = run_summary(reports)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Harness failed in candidate_lyrics_1.json', result.stderr)


if __name__ == '__main__':
    unittest.main()
