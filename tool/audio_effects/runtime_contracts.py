"""Actual-PCM contracts for resident channel modes and dry/warm limiter selection."""
import argparse
import json
import math
from pathlib import Path

from limiter import LIMITER_GRAPH
from native import run, probe
from runtime_graphs import (channel_mode_graph, warm_limiter_graph,
                            CHANNEL_MODE_TARGET, GUARD_MIX_TARGET)


def finish(report, actual, frames, behavior):
    report.update(frames=len(actual), expected_frames=len(frames))
    report['passed'] = (behavior and len(actual)==len(frames) and
        report['process'].get('return_code')==0 and report.get('end_file')=={'reason':0,'error':0} and
        report.get('initialized_handles')==1 and
        sum(row[0]==probe.FILE_LOADED for row in report.get('events',[]))==1 and
        all(math.isfinite(value) for row in actual for value in row) and
        not any(row['level'] in ('error','fatal') for row in report.get('logs',[])))
    print(report['name'], report['passed'], len(actual), flush=True)
    return report


def commands_ok(report, count):
    return len(report['updates'])==count and all(row['attempts'][-1].get('reply_error')==0 for row in report['updates'])


def weighted(left, right, weight):
    if weight == 1:
        return left
    if weight == 0:
        return right
    return left*weight+right*(1-weight)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libmpv', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = args.output.parent
    root.mkdir(parents=True, exist_ok=True)
    checks = []

    def capture(name, graph, frames, rate, **options):
        return run(root, args.libmpv.resolve(), name, graph, frames, rate, **options)

    for rate in (44100, 48000, 96000):
        for count in (49152, 49169):
            frames = [(round(26000*math.sin(n*.13)), round(21000*math.sin(n*.17+.3))) for n in range(count)]
            source = [[value/32768 for value in row] for row in frames]
            # Independent source-channel mapping, including the initial sample.
            for mode, mapping in enumerate(((0,1), (1,0), (0,0), (1,1))):
                report, actual = capture(f'channel_{rate}_{count}_{mode}',channel_mode_graph(mode),frames,rate)
                error = max((abs(row[ch]-original[mapping[ch]]) for row,original in zip(actual,source) for ch in (0,1)),default=math.inf)
                report['maximum_error'] = error
                checks.append(finish(report,actual,frames,error==0))
            report, actual = capture(f'channel_dynamic_{rate}_{count}',channel_mode_graph(diagnostic=True),frames,rate,
                output_channels=5, updates=((.05,1),(.15,2),(.25,3),(.35,0)), update_target=CHANNEL_MODE_TARGET)
            behavior = False
            if len(actual)==count:
                weights = [row[2:4] for row in actual]
                error = max(abs(row[ch]-weighted(*original,row[ch+2])) for row,original in zip(actual,source) for ch in (0,1))
                step = max(abs(b[ch]-a[ch]) for a,b in zip(weights,weights[1:]) for ch in (0,1))
                modes = [int(row[4]) for row in actual]
                observed = [value for n,value in enumerate(modes) if n==0 or value!=modes[n-1]]
                zero_error = max((abs(row[ch]-original[ch]) for row,original in zip(actual,source)
                                  if row[2:4]==(1.,0.) and row[4]==0 for ch in (0,1)),default=math.inf)
                tail_error = max(abs(row[ch]-original[ch]) for row,original in zip(actual[-128:],source[-128:]) for ch in (0,1))
                report.update(maximum_error=error, maximum_weight_step=step, observed_modes=observed,
                              neutral_error=zero_error, tail_neutral_error=tail_error, last_weights=weights[-1])
                behavior = (error<1e-6 and zero_error==0 and tail_error==0 and observed==[0,1,2,3,0] and
                    all(0<=value<=1 for row in weights for value in row) and weights[-1]==(1.,0.) and
                    1/(rate*.02)-1e-7 <= step <= 1/(rate*.02)+1e-7 and commands_ok(report,4))
            checks.append(finish(report,actual,frames,behavior))

            hot = [(round(32600*math.sin(2*math.pi*1000*n/rate)),
                    round(18000*math.sin(2*math.pi*1200*n/rate+.3))) for n in range(count)]
            original = [[value/32768 for value in row] for row in hot]
            base_report, limited = capture(f'limiter_baseline_{rate}_{count}',LIMITER_GRAPH,hot,rate)
            if not finish(base_report,limited,hot,True)['passed']:
                raise RuntimeError('Native always-on limiter comparison failed')
            for enabled in (False, True):
                report,actual = capture(f'guard_{rate}_{count}_{int(enabled)}',warm_limiter_graph(enabled),hot,rate)
                expected = limited if enabled else original
                error = max((abs(a-b) for row,ref in zip(actual,expected) for a,b in zip(row,ref)),default=math.inf)
                peak = max((abs(value) for row in actual for value in row),default=0)
                report.update(maximum_error=error,peak=peak)
                checks.append(finish(report,actual,hot,error==0 and (peak<=.97+1e-7 if enabled else peak>.99)))
            report,actual = capture(f'guard_dynamic_{rate}_{count}',warm_limiter_graph(diagnostic=True),hot,rate,
                output_channels=3,updates=((.05,1),(.15,0),(.25,1)),update_target=GUARD_MIX_TARGET)
            behavior = False
            if len(actual)==count:
                states = [row[2] for row in actual]
                observed = [value for n,value in enumerate(states) if n==0 or value!=states[n-1]]
                dry_error = max((abs(row[ch]-ref[ch]) for row,ref in zip(actual,original) if row[2]==0 for ch in (0,1)),default=math.inf)
                warm_error = max((abs(row[ch]-ref[ch]) for row,ref in zip(actual,limited) if row[2]==1 for ch in (0,1)),default=math.inf)
                peak = max((abs(row[ch]) for row in actual if row[2]==1 for ch in (0,1)),default=0)
                report.update(dry_error=dry_error,warm_error=warm_error,active_peak=peak,observed_guard_states=observed)
                behavior = (dry_error==0 and warm_error==0 and observed==[0,1,0,1] and
                            peak<=.97+1e-7 and commands_ok(report,3))
            checks.append(finish(report,actual,hot,behavior))
    args.output.write_text(json.dumps({'gate_status':'incomplete','checks':checks,
        'scope':'host native templates; no production orchestration or format-change resend verification',
        'sample_slew':'channel ear weights: 20ms full scale; limiter guard: immediate 0/1'},indent=2),encoding='utf-8')
    raise SystemExit(0 if all(row['passed'] for row in checks) else 1)


if __name__ == '__main__':
    main()
