"""Replay exact Dart-rendered production AF snapshots against native PCM."""
import argparse
import json
import math
from pathlib import Path
from native import run, probe
from graphs import scene_oracle
from eq_contracts import peaking_coefficients


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libmpv', type=Path, required=True)
    parser.add_argument('--graphs', type=Path, required=True)
    parser.add_argument('--variant', choices=['systemLibrary', 'customLibrary'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    graphs = json.loads(args.graphs.read_text())[args.variant]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    checks = []

    def capture(name, graph, frames, rate, expected=None, **options):
        report, actual = run(args.output.parent, args.libmpv.resolve(), name,
                             '', frames, rate, af_chain=graph, timeout=15, **options)
        error = max((abs(a-b) for row, ref in zip(actual, expected) for a,b in zip(row, ref)), default=math.inf) if expected is not None else 0
        report.update(frames=len(actual), expected_frames=len(frames), maximum_error=error)
        report['passed'] = (len(actual) == len(frames) and error < 1e-6 and
            report['process'].get('return_code') == 0 and report.get('end_file') == {'reason': 0, 'error': 0} and
            not any(row['level'] in ('error', 'fatal') for row in report.get('logs', [])) and
            all(math.isfinite(value) for row in actual for value in row))
        checks.append(report)
        print(name, report['passed'], len(actual), error, flush=True)
        return report, actual

    scene_tail = [
        (round(.97 * math.sin(2 * math.pi * 1000 * n / 48000) * 32767),
         round(.94 * math.sin(2 * math.pi * 1000 * n / 48000 + .15) * 32767))
        if n < 24000 else (0, 0) for n in range(33600)
    ]
    scene_input = [[value / 32768 for value in row] for row in scene_tail]
    amounts = [min(100, (n + 1) * 100 / 960) for n in range(len(scene_tail))]
    for scene, name in enumerate(('bathroom', 'through_wall', 'telephone')):
        expected = scene_oracle(scene_input, name, amounts, 48000)[0]
        capture(f'scene_tail_{name}_48000', graphs[f'scene_{scene}_100'],
                scene_tail, 48000, expected)

    for rate in (44100, 48000, 96000):
        frames = [(round(32600*math.sin(n*.13)), round(24000*math.sin(n*.17+.3))) for n in range(rate//5+17)]
        original = [[value/32768 for value in row] for row in frames]
        for name in ('dry', 'neutral'):
            capture(f'{name}_{rate}', graphs[name], frames, rate, original)
        for mode, mapping in enumerate(((0,1), (1,0), (0,0), (1,1))):
            capture(f'channel_{mode}_{rate}', graphs[f'channel_{mode}'], frames, rate,
                    [[row[mapping[0]], row[mapping[1]]] for row in original])
        scene_frames = [(12000 if n == 0 else round(5000*math.sin(n*.27)),
                         -8000 if n == 0 else round(7000*math.sin(n*.19))) for n in range(rate//5+17)]
        scene_input = [[value/32768 for value in row] for row in scene_frames]
        for scene, name in enumerate(('bathroom', 'through_wall', 'telephone')):
            for amount in (0, 50, 100):
                amounts = [min(amount, (n+1)*100/(rate*.02)) for n in range(len(scene_input))]
                expected = scene_oracle(scene_input, name, amounts, rate)[0]
                capture(f'scene_{scene}_{amount}_{rate}', graphs[f'scene_{scene}_{amount}'], scene_frames, rate, expected)
        sine = [(round(30000*math.sin(2*math.pi*1000*n/rate)),)*2 for n in range(rate//2+17)]
        report, cut = capture(f'eq_cut_{rate}', graphs['eq_cut'], sine, rate)
        if cut:
            ratio = math.sqrt(sum(row[0]**2 for row in cut[-rate//10:])/sum((row[0]/32768)**2 for row in sine[-rate//10:]))
            report['center_gain_db'] = 20*math.log10(ratio)
            report['passed'] &= abs(report['center_gain_db']+15)<.01
        report, boosted = capture(f'eq_boost_{rate}', graphs['eq_boost'], sine, rate)
        report['peak'] = max((abs(value) for row in boosted for value in row), default=0)
        report['passed'] &= .969 < report['peak'] <= .970001

    # A cut can overshoot: reverse the signs of its independently computed impulse.
    b0,b1,b2,a0,a1,a2 = peaking_coefficients(1000, -15, 48000)
    x1=x2=y1=y2=0.
    response=[]
    for n in range(4096):
        x=1. if n == 0 else 0.
        y=(b0*x+b1*x1+b2*x2-a1*y1-a2*y2)/a0
        response.append(y)
        x2,x1,y2,y1=x1,x,y1,y
    amplitude=round(.99*32767)
    signal=[(amplitude if value >= 0 else -amplitude,)*2 for value in reversed(response)]
    report, actual = capture('negative_only_transient', graphs['eq_cut'], signal, 48000)
    report['peak']=max((abs(value) for row in actual for value in row), default=0)
    report['passed'] &= .969 < report['peak'] <= .970001

    live = [(1000+n%997, -3000-n%991) for n in range(144017)]
    controls = graphs['controls']
    actions = [(0.05, command) for command in controls]
    report, actual = capture('resident_hot_controls', graphs['dry'], live, 48000,
                             actions=actions, actions_after_output=True)
    replies = report.get('actions', [])
    report['passed'] &= (len(replies) == len(controls) and
        all(row.get('reply_error') == 0 for row in replies) and
        report.get('initialized_handles') == 1 and
        sum(row[0] == probe.FILE_LOADED for row in report.get('events', [])) == 1)
    if len(actual) == len(live):
        report['passed'] &= (all(row == (source[0]/32768, source[1]/32768)
            for row,source in zip(actual[:128], live[:128])) and
            all(row == (source[1]/32768, source[0]/32768)
            for row,source in zip(actual[-128:], live[-128:])))

    args.output.write_text(json.dumps({'variant':args.variant,
        'scope':'exact Dart production snapshots on host reference; no device or OS claims',
        'checks':checks}, indent=2), encoding='utf-8')
    raise SystemExit(0 if all(row['passed'] for row in checks) else 1)


if __name__ == '__main__':
    main()
