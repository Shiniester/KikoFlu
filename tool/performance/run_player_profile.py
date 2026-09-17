"""Run the real-player Profile APK against staged local audio fixtures."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('label')
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', type=Path, default=Path('build/player_performance'))
    parser.add_argument('--start', type=int, default=1)
    parser.add_argument('--rounds', type=int, default=5)
    parser.add_argument('--no-ui', action='store_true')
    parser.add_argument('--no-audio', action='store_true')
    parser.add_argument('--stop', action='store_true')
    parser.add_argument('--races', action='store_true')
    parser.add_argument('--soak', type=int, default=0)
    parser.add_argument('--soak-index', type=int, default=0)
    parser.add_argument('--audio-repeats', type=int, default=2)
    args = parser.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9_-]+', args.label):
        parser.error('label must contain only letters, digits, _ or -')
    package = 'com.meteor.kikoeruflutter'
    remote = f'/sdcard/Android/data/{package}/files/player_performance'
    reports = args.output / 'reports'
    reports.mkdir(parents=True, exist_ok=True)

    def adb(*command, check=True):
        result = subprocess.run(
            ['adb', '-s', args.device, *command], capture_output=True,
            encoding='utf-8', errors='replace', timeout=60,
        )
        if check and result.returncode:
            raise RuntimeError(result.stderr or result.stdout)
        return result.stdout

    for number in range(args.start, args.start + args.rounds):
        control = dict(
            label=args.label, run=number, cycles=4, audioRepeats=args.audio_repeats,
            ui=not args.no_ui, audio=not args.no_audio, stopBeforeSwitch=args.stop,
            raceChecks=args.races, enforceLatest=args.races and args.label.startswith('candidate'),
            soakSeconds=args.soak, soakIndex=args.soak_index,
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
        # Create a readable output before the app writes it on external storage.
        empty_file = args.output / '.empty-report'
        empty_file.write_text('', encoding='utf-8')
        adb('push', str(empty_file), output)
        adb('shell', 'chmod', '666', output)
        adb('push', str(control_file), f'{remote}/control.json')
        adb('shell', 'am', 'force-stop', package)
        adb('shell', 'am', 'start', '-n', package + '/.MainActivity')
        print(f'{args.label} {number}: started', flush=True)
        started = time.monotonic()
        try:
            while time.monotonic() - started < max(1200, args.soak + 180):
                time.sleep(5)
                raw = adb('shell', 'cat', output, check=False).strip()
                try:
                    report = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                (reports / report_name).write_text(
                    json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8',
                )
                for check in report['checks']:
                    if check['case'] == 'harnessFailure':
                        raise RuntimeError(check['error'])
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
