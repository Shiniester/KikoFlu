"""Real PCM contracts for initial settings and native RC coefficient precision.

Unlike the 58-case suite, these checks isolate a 120 Hz step (sensitive to the
sendcmd formatter's significant digits) and an embedded scene-amount snapshot.
The native variant requires %.17g; the reference build's precision failures
are reported as failures rather than converted into expected successes.
"""
import argparse
import json
import math
from pathlib import Path

from adaptive_fs import rc_expression, rc_native_filters, scene_auto_graph, SCENE_AMOUNT_TARGET
from graphs import SCENES, rc, scene_oracle
from native import run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libmpv', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--native-rc', action='store_true')
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    checks = []
    for rate in (44100, 48000, 96000):
        frames = [(20000, -16000)]*(rate//10+17)
        alpha = rc(120, rate, True)
        previous = [0., 0.]
        expected = []
        for n, pair in enumerate(frames):
            # Independent one-pole RC step recurrence, including the input edge.
            previous = [alpha*(old+(value/32768 if n == 0 else 0))
                        for old, value in zip(previous, pair)]
            expected.append(previous)
        profile = dict(hp=120, hp_stages=1, lp=1200, lp_stages=0)
        filters = rc_native_filters(profile) if args.native_rc else rc_expression(120, True)
        graph = '[in]aformat=sample_fmts=dblp:channel_layouts=stereo,'+filters+'[out]'
        report, actual = run(args.output.parent, args.libmpv.resolve(), f'rc_step_120_{rate}', graph, frames, rate)
        report['max_error'] = (max(abs(a-b) for pair, ref in zip(actual, expected) for a,b in zip(pair,ref))
                               if len(actual) == len(expected) else math.inf)
        finish(report, actual, len(frames), report['max_error'] < 1e-6)
        checks.append(report)
    rate = 48000
    frames = [(round(18000*math.sin(n*.13)), round(14000*math.sin(n*.23))) for n in range(9617)]
    original = [[value/32768 for value in pair] for pair in frames]
    for name in SCENES:
        graph = scene_auto_graph(name, 50, dynamic=True, diagnostic=True, native_rc=args.native_rc)
        report, actual = run(args.output.parent, args.libmpv.resolve(), 'initial_amount_'+name,
                             graph, frames, rate, output_channels=3)
        intensity = [row[2] for row in actual]
        report['last_amount'] = intensity[-1] if intensity else None
        report['maximum_amount_step'] = max((abs(b-a) for a,b in zip(intensity,intensity[1:])), default=math.inf)
        report['runtime_target'] = SCENE_AMOUNT_TARGET
        expected, _ = scene_oracle(original, name, [amount*100 for amount in intensity], rate) if len(actual)==len(frames) else ([], 0)
        report['max_error'] = (max(abs(a-b) for pair, ref in zip(actual,expected) for a,b in zip(pair[:2],ref))
                               if expected else math.inf)
        finish(report, actual, len(frames), report['last_amount']==.5 and report['max_error']<1e-6 and
               report['maximum_amount_step'] <= 1/(rate*.02)+1e-7 and intensity[0]>0)
        checks.append(report)
    args.output.write_text(json.dumps({'gate_status':'incomplete',
        'rc_mode':'native_asendcmd_17g_required' if args.native_rc else 'expression',
        'checks':checks}, indent=2), encoding='utf-8')
    raise SystemExit(0 if all(row['passed'] for row in checks) else 1)


def finish(report, actual, expected_frames, behavior):
    report.update(frames=len(actual), expected_frames=expected_frames)
    report['passed'] = (behavior and len(actual)==expected_frames and
        report['process'].get('return_code')==0 and report.get('end_file')=={'reason':0,'error':0} and
        not any(row['level'] in ('error','fatal') for row in report.get('logs',[])))
    print(report['name'], report['passed'], len(actual), report.get('max_error'), flush=True)


if __name__ == '__main__':
    main()
