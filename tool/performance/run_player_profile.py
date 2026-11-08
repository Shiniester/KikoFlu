"""Run the real-player Profile APK against staged local audio fixtures."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

DEFAULT_PACKAGE = 'com.meteor.kikoeruflutter'
ACTIVITY_CLASS = 'com.meteor.kikoeruflutter.MainActivity'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('label')
    parser.add_argument('--device', required=True)
    parser.add_argument('--package', default=DEFAULT_PACKAGE)
    parser.add_argument('--output', type=Path, default=Path('build/player_performance'))
    parser.add_argument('--start', type=int, default=1)
    parser.add_argument('--rounds', type=int, default=5)
    parser.add_argument('--no-ui', action='store_true')
    parser.add_argument('--no-audio', action='store_true')
    parser.add_argument('--lyrics-only', action='store_true',
                        help='Measure only the full subtitle page on the real player route')
    parser.add_argument('--horizontal-only', action='store_true',
                        help='Measure horizontal dragging and release separately')
    parser.add_argument('--stop', action='store_true')
    parser.add_argument('--races', action='store_true')
    parser.add_argument('--seeks', action='store_true')
    parser.add_argument('--continuous-handoff', action='store_true')
    parser.add_argument('--soak', type=int, default=0)
    parser.add_argument('--soak-index', type=int, default=0)
    parser.add_argument('--audio-repeats', type=int, default=2)
    args = parser.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9_-]+', args.label):
        parser.error('label must contain only letters, digits, _ or -')
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+', args.package):
        parser.error('package must be a dotted Android application id')
    if args.continuous_handoff and (
        args.no_ui or not args.label.startswith('candidate')
    ):
        parser.error('--continuous-handoff requires a candidate UI run')
    if args.lyrics_only and (
        not args.no_audio or args.no_ui or args.horizontal_only or args.stop or
        args.races or args.seeks or args.continuous_handoff or args.soak > 0
    ):
        parser.error('--lyrics-only requires --no-audio and a UI-only run')
    repo_root = Path(__file__).resolve().parents[2]
    source_sha = subprocess.run(
        ['git', 'rev-parse', 'HEAD'], cwd=repo_root, capture_output=True,
        encoding='utf-8', check=True,
    ).stdout.strip()
    package = args.package
    remote = f'/data/user/0/{package}/files/player_performance'
    reports = args.output / 'reports'
    reports.mkdir(parents=True, exist_ok=True)
    child_env = os.environ.copy()
    for name in ('NO_PROXY', 'no_proxy'):
        entries = [entry for entry in child_env.get(name, '').split(',') if entry]
        child_env[name] = ','.join(dict.fromkeys(
            [*entries, '127.0.0.1', 'localhost', '::1'],
        ))

    def adb(*command, check=True):
        result = subprocess.run(
            ['adb', '-s', args.device, *command], capture_output=True,
            encoding='utf-8', errors='replace', timeout=60, env=child_env,
        )
        if check and result.returncode:
            raise RuntimeError(result.stderr or result.stdout)
        return result.stdout

    def run_as(*command, check=True):
        return adb('shell', 'run-as', package, *command, check=check)

    staging_path = '/data/local/tmp/kikoflu-player-profile-stage'

    def stage_file(source, destination):
        adb('push', str(source), staging_path)
        try:
            run_as('cp', staging_path, destination)
        finally:
            adb('shell', 'rm', '-f', staging_path, check=False)

    for number in range(args.start, args.start + args.rounds):
        control = dict(
            label=args.label, run=number, cycles=4, audioRepeats=args.audio_repeats,
            package=package,
            ui=not args.no_ui, audio=not args.no_audio, stopBeforeSwitch=args.stop,
            raceChecks=args.races, enforceLatest=args.races and args.label.startswith('candidate'),
            seekChecks=args.seeks,
            lyricsOnly=args.lyrics_only,
            continuousHandoff=args.continuous_handoff,
            horizontalOnly=args.horizontal_only,
            soakSeconds=args.soak, soakIndex=args.soak_index,
            sourceSha=source_sha,
        )
        environment = {
            name: adb('shell', 'dumpsys', name)
            for name in ['thermalservice', 'battery', 'display']
        }
        (reports / f'{args.label}_{number}_environment.json').write_text(
            json.dumps(environment, indent=2), encoding='utf-8',
        )
        thermal = re.search(r'Thermal Status: (\d+)', environment['thermalservice'])
        if thermal is None or int(thermal[1]) > 2:
            raise RuntimeError('Device must report thermal status 0, 1 or 2 before testing')
        control_file = args.output / 'control.json'
        control_file.write_text(json.dumps(control), encoding='utf-8')
        report_name = f'{args.label}_{number}.json'
        output = f'{remote}/{report_name}'
        run_as('mkdir', '-p', remote)
        # App-private files are written by the profile app UID.
        empty_file = args.output / '.empty-report'
        empty_file.write_text('', encoding='utf-8')
        stage_file(empty_file, output)
        stage_file(empty_file, f'{remote}/bootstrap_failure.json')
        stage_file(control_file, f'{remote}/control.json')
        adb('shell', 'am', 'force-stop', package)
        adb('shell', 'am', 'start', '-n', package + '/' + ACTIVITY_CLASS)
        print(f'{args.label} {number}: started', flush=True)
        started = time.monotonic()
        try:
            while time.monotonic() - started < max(1200, args.soak + 180):
                time.sleep(5)
                bootstrap_raw = run_as(
                    'cat', f'{remote}/bootstrap_failure.json', check=False,
                ).strip()
                if bootstrap_raw:
                    try:
                        bootstrap = json.loads(bootstrap_raw)
                    except json.JSONDecodeError:
                        bootstrap = None
                    if bootstrap is not None:
                        (reports / f'{args.label}_{number}_bootstrap_failure.json').write_text(
                            json.dumps(bootstrap, ensure_ascii=False, indent=2),
                            encoding='utf-8',
                        )
                        failure = next(
                            (check for check in bootstrap.get('checks', [])
                             if check.get('case') == 'harnessFailure'),
                            None,
                        )
                        if failure is not None:
                            raise RuntimeError(failure.get('error', str(failure)))
                raw = run_as('cat', output, check=False).strip()
                try:
                    report = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                (reports / report_name).write_text(
                    json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8',
                )
                harness_failure = next(
                    (check for check in report.get('checks', [])
                     if check.get('case') == 'harnessFailure'),
                    None,
                )
                if harness_failure is not None:
                    raise RuntimeError(harness_failure.get('error', str(harness_failure)))
                if (report['control'] != control or report['run']['run'] != number):
                    raise RuntimeError('Profile report does not match the requested run')
                if args.continuous_handoff:
                    checks = [check for check in report['checks']
                              if check['case'] == 'queueContinuousHandoff']
                    if len(checks) != 1 or checks[0].get('passed') is not True:
                        raise RuntimeError('Continuous queue handoff check is missing or failed')
                    if report['run']['metrics'].get('queueContinuousHandoffFrameCount', 0) <= 0:
                        raise RuntimeError('Continuous queue handoff did not record any frames')
                if args.lyrics_only:
                    hidden_checks = [check for check in report['checks']
                                     if check['case'] == 'lyricHiddenIdle']
                    if len(hidden_checks) != 1:
                        raise RuntimeError('Hidden subtitle idle check is missing')
                    if (args.label.startswith('candidate') and
                            hidden_checks[0].get('passed') is not True):
                        raise RuntimeError(f'Hidden subtitle page kept rendering: {hidden_checks[0]}')
                for check in report['checks']:
                    if check['case'] == 'harnessFailure':
                        raise RuntimeError(check['error'])
                    if check['case'].startswith('seek-') and not check['passed']:
                        raise RuntimeError(f'Seek playback check failed: {check}')
                    if (check['case'] == 'queueContinuousHandoff' and
                            not check['passed']):
                        raise RuntimeError(f'Queue handoff check failed: {check}')
                    if control['enforceLatest'] and 'expected' in check:
                        if (check['actual'] != check['expected'] or
                                check['published'] != [check['expected']] or
                                check['errors'] or not check['cachePreserved']):
                            raise RuntimeError(f'Latest-request check failed: {check}')
                    if check['case'] == 'continuousPlayback':
                        if not check['playing'] or check['advancedMs'] < args.soak * 950:
                            raise RuntimeError(f'Continuous playback failed: {check}')
                print(json.dumps(dict(
                    label=args.label, run=number,
                    sourceSha=source_sha,
                    durationSeconds=round(time.monotonic() - started),
                    metrics=report['run']['metrics'], switches=len(report['switchSamples']),
                    checks=report['checks'],
                ), ensure_ascii=False), flush=True)
                break
            else:
                raise TimeoutError(output)
        finally:
            adb('shell', 'am', 'force-stop', package)


if __name__ == '__main__':
    main()
