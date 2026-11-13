"""Actual PCM from the app-rendered binaural graph and complete output chain."""
import argparse
import json
import math
from pathlib import Path
from native import run, probe
from adaptive_fs import mono_oracle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libmpv', type=Path, required=True)
    parser.add_argument('--graphs', type=Path, required=True)
    parser.add_argument('--variant', choices=['systemLibrary', 'customLibrary'], default='systemLibrary')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    graphs = json.loads(args.graphs.read_text(encoding='utf-8'))[args.variant]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    checks = []

    def capture(name, graph, frames, rate, expected=None, chain=False, **options):
        report, actual = run(args.output.parent, args.libmpv.resolve(), name,
            '' if chain else graph, frames, rate, timeout=15,
            af_chain=graph if chain else None, **options)
        error = max((abs(a-b) for row,ref in zip(actual,expected) for a,b in zip(row,ref)), default=0) if expected is not None else 0
        report.update(frames=len(actual), expected_frames=len(frames), maximum_error=error)
        report['passed'] = (len(actual)==len(frames) and error<1e-6 and
            report['process'].get('return_code')==0 and report.get('end_file')=={'reason':0,'error':0} and
            all(math.isfinite(v) for row in actual for v in row) and
            not any(row['level'] in ('error','fatal') for row in report.get('logs',[])))
        checks.append(report)
        return report,actual

    for rate in (44100,48000,96000):
        aligned=math.ceil(rate*.35/4096)*4096
        for count in (17,aligned,aligned+17):
            frames=[(round(6000*math.sin(n*.17)),round(4000*math.sin(n*.23+.3))) for n in range(count)]
            source=[(l/32768,r/32768) for l,r in frames]
            for mode in ('stereo','mono'):
                for percent in (0,50,100):
                    amount=percent/100
                    expected=mono_oracle(source,rate,amount) if mode=='mono' else [
                        (l+(l-r)/2*min(amount,(n+1)/(rate*.02)),r-(l-r)/2*min(amount,(n+1)/(rate*.02)))
                        for n,(l,r) in enumerate(source)]
                    report,actual=capture(f'linear_{mode}_{percent}_{rate}_{count}',graphs[f'linear_{mode}_{percent}'],frames,rate,expected)
                    mid_error=max((abs((l+r)/2-(a+b)/2) for (l,r),(a,b) in zip(actual,source)),default=0)
                    report['common_error']=mid_error
                    report['passed'] &= mid_error<1e-7
                    if percent==0: report['passed'] &= actual==source
            # Opposite channels have no common content to decorrelate.
            opposite=[(l,-l) for l,_ in frames]
            reference=[(l/32768,r/32768) for l,r in opposite]
            report,actual=capture(f'mono_retains_side_{rate}_{count}',graphs['linear_mono_100'],opposite,rate,reference)
            report['passed'] &= actual==reference
            identical=[(l,l) for l,_ in frames]
            reference=[(l/32768,r/32768) for l,r in identical]
            report,actual=capture(f'stereo_identical_{rate}_{count}',graphs['linear_stereo_100'],identical,rate,reference)
            report['passed'] &= actual==reference

        # Decode a real one-channel source through the same production conversion.
        mono_source=[(round(6000*math.sin(n*.19)),) for n in range(aligned+17)]
        baseline,decoded=capture(f'one_channel_dry_{rate}',graphs['dry'],mono_source,rate,chain=True)
        report,neutral=capture(f'one_channel_zero_{rate}',graphs['binaural_mono_0'],mono_source,rate,decoded,chain=True)
        report['passed'] &= neutral==decoded
        report,expanded=capture(f'one_channel_expanded_{rate}',graphs['binaural_mono_100'],mono_source,rate,
            mono_oracle(decoded,rate,1),chain=True)
        report['passed'] &= any(abs(l-r)>1e-5 for l,r in expanded)

        # Protect an isolated onset and constrain the generated difference after silence.
        frames=[(round(12000*math.sin(2*math.pi*1300*n/rate)),)*2
            if rate//10<=n<rate//5 else (0,0) for n in range(aligned+17)]
        source=[(l/32768,r/32768) for l,r in frames]
        report,protected=capture(f'mono_transient_tail_{rate}',graphs['linear_mono_100'],frames,rate,mono_oracle(source,rate,1))
        unprotected=graphs['linear_mono_100'].replace('*(1-ld(4))*min(1,ld(1)/(ld(5)+1e-12))','')
        bare_report,bare=capture(f'mono_unprotected_comparison_{rate}',unprotected,frames,rate)
        onset=range(rate//10,int(rate*.1002))
        protected_peak=max((abs((protected[n][0]-protected[n][1])/2) for n in onset),default=0) if len(protected)==len(frames) else math.inf
        bare_peak=max((abs((bare[n][0]-bare[n][1])/2) for n in onset),default=0) if len(bare)==len(frames) else 0
        tail=max((abs(v) for row in protected[int(rate*.23):] for v in row),default=math.inf)
        report.update(onset_side_peak=protected_peak,comparison_onset_side_peak=bare_peak,tail_after_30ms_peak=tail)
        report['passed'] &= bare_peak>.01 and protected_peak<bare_peak*.1 and tail<1e-5

        hot=[(round(32600*math.sin(n*.13)),round(-32600*math.sin(n*.17))) for n in range(aligned+17)]
        original=[(l/32768,r/32768) for l,r in hot]
        for mode in ('stereo','mono'):
            capture(f'production_zero_{mode}_{rate}',graphs[f'binaural_{mode}_0'],hot,rate,original,chain=True)
            report,actual=capture(f'production_guard_{mode}_{rate}',graphs[f'binaural_{mode}_100'],hot,rate,chain=True)
            report['peak']=max((abs(v) for row in actual for v in row),default=math.inf)
            report['passed'] &= report['peak']<=.970001

        # Real commands must switch modes before EOF and retain common content.
        frames=[(round(6000*math.sin(n*.13)),round(4000*math.sin(n*.17))) for n in range(rate*6+17)]
        source=[(l/32768,r/32768) for l,r in frames]
        actions=[(1,command) for command in graphs['binauralControls']['mono']]
        report,actual=capture(f'production_hot_modes_{rate}',graphs['binaural_stereo_100'],frames,rate,
            chain=True,actions=actions,actions_after_output=True)
        if len(actual)==len(source):
            expected_mono=mono_oracle(source,rate,1)
            def longest_matches(expected):
                start=best_start=best_length=0
                for n,(row,ref) in enumerate(zip(actual,expected)):
                    if max(abs(a-b) for a,b in zip(row,ref))>=1e-6:
                        start=n+1
                    elif n+1-start>best_length:
                        best_start,best_length=start,n+1-start
                return best_start,best_length
            stereo_expected=[(l+(l-r)/2,r-(l-r)/2) for l,r in source]
            stereo_start,stereo_count=longest_matches(stereo_expected)
            mono_start,mono_count=longest_matches(expected_mono)
            mid_error=max(abs(sum(row)-sum(ref)) for row,ref in zip(actual,source))
            neutral_between=any(actual[n]==source[n] for n in range(stereo_start+stereo_count,mono_start))
            report.update(stereo_stable_start=stereo_start,stereo_stable_frames=stereo_count,
                mono_stable_start=mono_start,mono_stable_frames=mono_count,neutral_between_modes=neutral_between,linear_sum_error=mid_error)
            report['passed'] &= (stereo_count>rate//5 and mono_count>rate//5 and
                stereo_start<mono_start and neutral_between and mid_error<2e-7 and
                actual[-rate//5:]==expected_mono[-rate//5:])
        report['passed'] &= (len(report.get('actions',[]))==len(actions) and
            all(row.get('reply_error')==0 for row in report.get('actions',[])) and
            report.get('initialized_handles')==1 and sum(row[0]==probe.FILE_LOADED for row in report.get('events',[]))==1)

        print(rate, sum(row['passed'] for row in checks), '/', len(checks), flush=True)

    args.output.write_text(json.dumps({'variant':args.variant,'scope':'actual app-rendered graphs; no device or headphone listening claim','checks':checks},indent=2),encoding='utf-8')
    print('failures:', [row['name'] for row in checks if not row['passed']], flush=True)
    raise SystemExit(0 if all(row['passed'] for row in checks) else 1)


if __name__=='__main__':
    main()
