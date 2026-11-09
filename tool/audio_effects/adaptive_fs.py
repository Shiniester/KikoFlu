"""Actual-Fs graph templates; baseline graphs and production registration stay separate.

Use one labeled mpv lavfi node per module, preceded by mpv format=channels=stereo,
with o=[threads=1]. Amount commands target the named volume instance; FFmpeg n6
needs the bare instance name on a failed full-name command, never a type broadcast.
Native RC requires the project's asendcmd %.17g build; it never falls back to AEval.
"""
import argparse
import json
import math
import re
import struct
import wave
from pathlib import Path
from native import run, write_wav
from composite import module_chain, combination_frames
from basic import equalizer_graph
from limiter import LIMITER_GRAPH
from graphs import mono_graph, scene_graph, scene_oracle, scene_dynamic_graph, SCENES

MONO_AMOUNT_TARGET = "volume@mono_amount"
SCENE_AMOUNT_TARGET = "volume@scene_amount"
# ['af-command', module_label, 'volume', str(amount_0_to_1), target]
# Retry only an actual -12 response with target.split('@', 1)[1].


def allpass_stage(prefix, source, output, ms, gain, channels="stereo"):
    seed_duration = (ms + 1) / 1000
    p = prefix
    return (
        f"[{source}]asplit=2[{p}work][{p}si];"
        f"[{p}si]atrim=duration={seed_duration},asetnsamples=n=1:p=0,"
        f"aselect='lt(n,max(1,floor(sample_rate*{ms}/1000+.5)))',"
        f"asetnsamples=n=4096:p=0,aeval=0:c=same,asetpts=N/SR/TB[{p}seed];"
        # An extra work-only sample lets n6 cyclic joins drain an aligned EOF.
        # The original mid/dry input, outside this stage, still bounds output N.
        f"[{p}work]apad=pad_len=1,asetnsamples=n=4096:p=1,asetpts=N/SR/TB[{p}x];"
        f"[{p}seed][{p}fb]concat=n=2:v=0:a=1,asplit=2[{p}dw][{p}dy];"
        f"[{p}dw]aeval='val(ch)*{-gain}':c=same[{p}neg];"
        f"[{p}neg][{p}x]amix=inputs=2:normalize=0:duration=shortest,"
        f"asplit=2[{p}fb][{p}w];"
        f"[{p}w]aeval='val(ch)*{gain}':c=same[{p}gw];"
        f"[{p}dy][{p}gw]amix=inputs=2:normalize=0:duration=shortest[{p}y];"
        f"[{p}y]aformat=sample_fmts=dblp:channel_layouts={channels}[{output}]"
    )


def allpass_graph(ms=.7, gain=.5):
    return ("[in]aformat=sample_fmts=dblp:channel_layouts=stereo,asplit=2[dry][x];" +
        allpass_stage("a", "x", "effect", ms, gain) + ";" +
        "[dry][effect]join=inputs=2:channel_layout=4.0:map=0.0-FL|0.1-FR|1.0-FC|1.1-BC,"
        "aeval='val(2)|val(3)':c=stereo,aformat=channel_layouts=stereo[out]")


def allpass_oracle(frames, rate, ms=.7, gain=.5):
    delay = max(1, int(rate * ms / 1000 + .5))
    history, result = [], []
    for n, pair in enumerate(frames):
        delayed = history[n-delay] if n >= delay else [0] * len(pair)
        written = [value-gain*old for value, old in zip(pair, delayed)]
        result.append([gain*value+old for value, old in zip(written, delayed)])
        history.append(written)
    return result



def mono_auto_graph(amount):
    """Stereo widening, amount 0..1; native control ramps from zero over 20 ms."""
    base = mono_graph(48000).replace('volume@mono_amount=0:', f'volume@mono_amount={amount}:')
    base = base.replace('[ctl]aeval=1', '[ctl]apad=pad_len=1,asetnsamples=n=4096:p=1,aeval=1',1)
    # Registers 0..5 hold the original envelope/history. Constants occupy 6..9
    # and are recreated by lavfi when the actual input sample rate changes.
    base = base.replace('exp(-1/(s*.003))', 'ld(6)')
    base = base.replace('(1-exp(-1/(s*.02)))', 'ld(7)')
    base = base.replace('exp(-1/(s*.01))', 'ld(8)')
    base = base.replace('1/(s*.02)', 'ld(9)')
    base = base.replace("[pack]aeval='", "[pack]aeval='if(eq(n,0),"
        "st(6,exp(-1/(s*.003)));st(7,1-exp(-1/(s*.02)));"
        "st(8,exp(-1/(s*.01)));st(9,1/(s*.02)));")
    stages = [(.7, .5), (1.1, -.5), (1.7, .5)]
    replacement = ''.join(allpass_stage(f'ap{k}', 'api' if k == 0 else f'ap{k-1}',
        'ap' if k == 2 else f'ap{k}', ms, gain, 'mono') + ';'
        for k, (ms, gain) in enumerate(stages))
    return re.sub(r';\[api\].*?\[ap\];', lambda _: ';'+replacement, base, count=1)


def mono_oracle(frames, rate, amount):
    mid = [[sum(pair)/2] for pair in frames]
    processed = mid
    for ms, gain in ((.7,.5),(1.1,-.5),(1.7,.5)):
        processed = allpass_oracle(processed, rate, ms, gain)
    intensity = peak = slow = onset = difference_peak = 0.
    result = []
    for pair, m, ap in zip(frames, mid, processed):
        value, filtered = m[0], ap[0]
        intensity += max(-1/(rate*.02), min(1/(rate*.02), amount-intensity))
        peak = max(abs(value), peak*math.exp(-1/(rate*.003)))
        strength = max(0, min(1, (abs(value)-2*slow)/(abs(value)+1e-12)))
        slow += (abs(value)-slow)*(1-math.exp(-1/(rate*.02)))
        onset = max(strength, onset*math.exp(-1/(rate*.01)))
        difference_peak = max(abs(filtered-value), difference_peak*math.exp(-1/(rate*.003)))
        side = .5*(filtered-value)*intensity*(1-onset)*min(1,peak/(difference_peak+1e-12))
        result.append((pair[0]+side, pair[1]-side))
    return result


def zero_seed(source, output, ms, rounded=False):
    offset = '+.5' if rounded else ''
    return (f'[{source}]asetpts=N/SR/TB,atrim=duration={(ms+1)/1000},asetnsamples=n=1:p=0,'
        f"aselect='lt(n,max(1,floor(sample_rate*{ms}/1000{offset})))',"
        f'asetnsamples=n=4096:p=0,aeval=0:c=same,asetpts=N/SR/TB[{output}]')


def delay(source, output, ms, prefix):
    return (f'[{source}]asplit=2[{prefix}s][{prefix}x];' +
        zero_seed(f'{prefix}s', f'{prefix}z', ms) + ';' +
        f'[{prefix}x]asetpts=N/SR/TB[{prefix}t];'
        f'[{prefix}z][{prefix}t]concat=n=2:v=0:a=1,asetnsamples=n=128:p=0[{output}]')


def rc_expression(cutoff, high):
    numerator = 's' if high else f'2*PI*clip({cutoff},10,s*.45)'
    ceiling = '.9999' if high else '1'
    alpha = f'max(.0001,min({ceiling},({numerator})/(s+2*PI*clip({cutoff},10,s*.45))))'
    expressions = []
    for ch in (0,1):
        recurrence = f'ld(0)*(ld(1)+val({ch})-ld(2))' if high else f'ld(1)+ld(0)*(val({ch})-ld(1))'
        expressions.append(f'if(eq(n,0),st(0,{alpha});st(1,0);st(2,0));'
            f'st(1,{recurrence});st(2,val({ch}));ld(1)')
    return "aeval='" + '|'.join(expressions) + "':c=stereo,aformat=sample_fmts=dblp:channel_layouts=stereo"


def rc_native_filters(profile):
    """Native biquad coefficients from actual Fs, before processing frame zero.

    In a 1/Fs time base, (N+1)/((N+1)/Fs) is Fs, including the first sample.
    Work input is already blocked at 128 samples; 0..1 ms sends once at Fs<=96k.
    The original dry branch retains its timestamps and limits the final length.
    Both instance spellings receive identical coefficients, reset=0; an unmatched
    spelling is only a verbose sendcmd message on the supported FFmpeg versions.
    """
    commands, filters = [], []
    index = 0
    for high, key in ((True, 'hp'), (False, 'lp')):
        cutoff = f'max(10,min({profile[key]},.45*PTS/T))'
        denominator = f'(PTS+2*PI*({cutoff})*T)'
        value = f'PTS/{denominator}' if high else f'2*PI*({cutoff})*T/{denominator}'
        alpha = f"clip({value},.0001,{'.9999' if high else '1'})"
        for _ in range(profile[key+'_stages']):
            name = f'rc{index}'
            coefficients = [('b0', alpha), ('b1', '-('+alpha+')' if high else '0'),
                            ('a1', '-('+alpha+')' if high else '('+alpha+')-1')]
            for coefficient, expression in coefficients:
                # Lavfi option parsing consumes one layer before sendcmd parsing.
                argument = expression.replace(',', r'\\,')
                for target in ('biquad@'+name, name):
                    commands.append(f'[enter+expr] {target} {coefficient} {argument}')
            filters.append(f'biquad@{name}=b0=1:b1=0:b2=0:a0=1:a1=0:a2=0:precision=f64')
            index += 1
    return ("asettb=expr=1/sr,asetpts=N+1,asendcmd=c='0.0-0.001 " +
            ', '.join(commands) + ";',asetpts=PTS-1," + ','.join(filters) +
            ',aformat=sample_fmts=dblp:channel_layouts=stereo')


def _cache_scene_parameters(graph, profile):
    """Cache sample-local parameters until the smoothed amount changes.

    Zero amount preserves the original bypass and warm RC/reflection histories.
    Every nonzero amount change rewrites the complete cached parameter set.
    """
    pre = []
    for ch in (0, 1):
        pre.append(f"if(val(2),if(eq(val(2),ld(0)),0,st(0,val(2));"
            "st(1,ld(0)*(1+.45*ld(0)*ld(0)));st(2,min(1,ld(0)*(1+.2*ld(0))));"
            f"st(3,(1+({profile['width']}-1)*ld(2))*(1-min(1,{profile['mono']}*ld(1)))));"
            f"(val(0)+val(1))/2+(val({ch})-(val(0)+val(1))/2)*ld(3),val({ch}))")
    graph = re.sub(r"\[pre\]aeval='[^']*'", lambda _: "[pre]aeval='"+'|'.join(pre)+"'", graph)
    taps = bool(profile['taps'])
    if taps:
        feedback = [f"if(val(4),if(eq(val(4),ld(0)),0,st(0,val(4));"
            f"st(1,min(.88,{profile['feedback']}*ld(0)*(1+.45*ld(0)*ld(0)))));"
            f"clip(val({ch+2})+ld(1)*val({ch}),-1.25,1.25),clip(val({ch+2}),-1.25,1.25))"
            for ch in (0, 1)]
        graph = re.sub(r"\[recurrence\]aeval='[^']*'",
                       lambda _: "[recurrence]aeval='"+'|'.join(feedback)+"'", graph)
    final = []
    intensity = 6 if taps else 4
    for ch in (0, 1):
        initialize = (f"st(0,val({intensity}));st(1,ld(0)*(1+.45*ld(0)*ld(0)));"
            "st(9,min(1,ld(0)*(1+.2*ld(0))));"
            f"st(2,1+({profile['dry']}-1)*ld(9));st(3,1+({profile['gain']}-1)*ld(0));"
            f"st(6,{profile['direct']}*ld(1))")
        reflection = f'+ld(7)*val({ch+4})' if taps else ''
        if taps:
            initialize += f";st(7,{profile['reflection']}*ld(1))"
        if profile['drive']:
            initialize += f";st(4,1+4*({profile['drive']}*ld(1)));st(5,tanh(ld(4)))"
            output = 'tanh(clip(ld(8)*ld(4),-8,8))/ld(5)'
        else:
            output = 'ld(8)'
        final.append(f"if(val({intensity}),if(eq(val({intensity}),ld(0)),0,{initialize});"
            f"st(8,ld(3)*(ld(2)*val({ch})+ld(6)*val({ch+2}){reflection}));"
            f"clip({output},-1,1),val({ch}))")
    return re.sub(r"\[final\]aeval='[^']*'",
                  lambda _: "[final]aeval='"+'|'.join(final)+"'", graph)


def scene_auto_graph(name, amount, dynamic=False, diagnostic=False, native_rc=False):
    """Eara scene, amount 0..100, optionally with a runtime volume control.

    Dynamic initial amount fills scene_amount with amount/100; after reconfigure
    the native 20 ms ramp starts at zero. Resend the latest setting on native
    audio-reconfig; embedding a snapshot does not preserve later commands.
    Keep dynamic=True for resident targets even at zero; static zero is anull.
    native_rc=True requires asendcmd %.17g, with no automatic precision fallback.
    """
    base = scene_dynamic_graph(name, diagnostic=diagnostic) if dynamic else scene_graph(name, amount)
    if amount == 0 and not dynamic:
        return base
    profile = SCENES[name]
    if dynamic:
        base = base.replace('volume@scene_amount=0:', f'volume@scene_amount={amount/100:.17g}:', 1)
        base = _cache_scene_parameters(base, profile)
    base = base.replace('[seed][fb]concat=n=2:v=0:a=1[delayed]',
        '[seed][fb]concat=n=2:v=0:a=1,asetnsamples=n=128:p=0[delayed]')
    if dynamic:
        base = base.replace('concat=n=2:v=0:a=1, aformat=',
            'concat=n=2:v=0:a=1,asetnsamples=n=128:p=0,aformat=')
    if native_rc:
        existing = re.findall(r'biquad=[^,;\[]+', base)
        base = base.replace(','.join(existing), rc_native_filters(profile), 1)
    else:
        replacements = [rc_expression(profile[key], high)
            for high,key in ((True,'hp'),(False,'lp'))
            for _ in range(profile[key+'_stages'])]
        iterator = iter(replacements)
        base = re.sub(r'biquad=[^,;\[]+', lambda _: next(iterator), base)
    base = base.replace('[raw]pan=', '[raw]asetnsamples=n=128:p=1,pan=')
    if profile['taps']:
        if not dynamic:
            def final_mix(match):
                dry, direct, reflection = match.group(1).split()
                expressions = [f'{dry}*val({ch})+{direct}*val({ch+2})+{reflection}*val({ch+4})' for ch in (0,1)]
                return ("[dry][direct][reflection]join=inputs=3:channel_layout=5.1:"
                    "map=0.0-FL|0.1-FR|1.0-FC|1.1-LFE|2.0-BL|2.1-BR,aeval='" +
                    '|'.join(expressions) + "':c=stereo,aformat=sample_fmts=dblp:channel_layouts=stereo,")
            base = re.sub(r"\[dry\]\[direct\]\[reflection\]amix=inputs=3:normalize=0:duration=first:weights='([^']*)',",
                          final_mix, base)
        base = base.replace('asplit=2[dry][work]', 'asplit=3[dry][work][seed_source]', 1) if dynamic else base.replace('asplit=2[dry][raw]', 'asplit=3[dry][raw][seed_source]', 1)
        base = re.sub(r'anullsrc=.*?\[seed\]',
            lambda _: zero_seed('seed_source','seed', profile['taps'][-1][0]), base, count=1)
        for k,(ms,gain) in enumerate(profile['taps']):
            old = f'[t{k}]adelay={ms*48000//1000}S:all=1,'
            base = base.replace(old, delay(f't{k}',f'd{k}',ms,f'tap{k}')+f';[d{k}]')
    return base

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libmpv', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--native-rc', action='store_true',
                        help='use native biquad/asendcmd; requires the %%.17g build, no fallback')
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    def make_scene(name, amount, **options):
        return scene_auto_graph(name, amount, native_rc=args.native_rc, **options)
    checks = []
    def check(name, graph, frames, rate, expected, exact=False, **options):
        report, actual = run(args.output.parent, args.libmpv.resolve(), name,
                             graph, frames, rate, timeout=12, **options)
        if callable(expected):
            if len(actual) != len(frames):
                report.update(frames=len(actual), expected_frames=len(frames), passed=False,
                              reason="native PCM frame count differs before the varying-amount oracle")
                checks.append(report)
                print(name, False, len(actual), len(frames), flush=True)
                return report, actual
            expected = expected(actual)
        report['frames'] = len(actual)
        report['expected_frames'] = len(expected)
        if len(actual) == len(expected):
            report['max_error'] = max(abs(a-b) for pair, ref in zip(actual,expected) for a,b in zip(pair,ref))
        report['passed'] = (report['process'].get('return_code') == 0 and
                            report.get('end_file') == {'reason':0,'error':0} and
                            (report.get('max_error', math.inf) == 0 if exact else report.get('max_error', math.inf) < 1e-6) and
                            not any(x['level'] in ('error', 'fatal') for x in report.get('logs',[])))
        checks.append(report)
        print(name, report['passed'], report.get('max_error'), len(actual), flush=True)
        return report, actual

    for rate in (44100, 48000, 96000):
        frames = [(12000 if n == 0 else round(5000*math.sin(n*.27)),
                   -8000 if n == 0 else round(7000*math.sin(n*.19))) for n in range(rate//10+17)]
        normalized = [[x/32768 for x in pair] for pair in frames]
        cases = [('ap', allpass_graph(), allpass_oracle(normalized,rate))]
        for amount in (0,1):
            cases.append((f'mono_{amount}', mono_auto_graph(amount), mono_oracle(normalized,rate,amount)))
        for scene in SCENES:
            for amount in (0,50,100):
                cases.append((f'{scene}_{amount}', make_scene(scene,amount), scene_oracle(normalized,scene,amount,rate)[0]))
        for label,graph,expected in cases:
            name = f'auto_{label}_{rate}'
            check(name, graph, frames, rate, expected, exact=label.endswith('_0'))
        loud = [(round(.97*32767*math.sin(2*math.pi*1000*n/rate)),
                 round(.94*32767*math.sin(2*math.pi*1000*n/rate+.15)))
                 if n < rate//2 else (0,0) for n in range(rate*7//10+17)]
        expected, clips = scene_oracle([[v/32768 for v in pair] for pair in loud], 'bathroom',100,rate)
        report,_ = check(f'auto_bathroom_feedback_{rate}', make_scene('bathroom',100), loud, rate, expected)
        report['oracle_feedback_write_clips'] = clips
        report['passed'] &= clips > 0
        source = args.output.parent/f'clip-{rate}.wav'
        write_wav(source, frames, rate)
        for label,baseline,candidate in (
            ('mono',mono_graph(rate).replace('volume@mono_amount=0:', 'volume@mono_amount=1:'), mono_auto_graph(1)),
            ('rc',scene_graph('telephone',100,rate),make_scene('telephone',100))):
            baseline_report, baseline_pcm = run(args.output.parent,args.libmpv.resolve(),
                f'baseline_{label}_clip_{rate}',baseline,frames,rate,
                source_url=str(source.resolve()),start_position=.05)
            if (baseline_report['process'].get('return_code') != 0 or not baseline_pcm or
                any(row['level'] in ('error','fatal') for row in baseline_report.get('logs',[]))):
                raise RuntimeError('Native accepted clip baseline failed')
            report,_ = check(f'auto_{label}_clip_{rate}',candidate,frames,rate,baseline_pcm,
                source_url=str(source.resolve()),start_position=.05)
            report['oracle_scope'] = 'same native start/preroll as accepted baseline; full-input cases use independent recurrence'
        dynamic_frames = [(round(.95*32767*math.sin(2*math.pi*1000*n/rate)),
                           round(.8*32767*math.sin(2*math.pi*700*n/rate+.2)))
                           for n in range(rate*13//10+17)]
        original = [[v/32768 for v in pair] for pair in dynamic_frames]
        for scene in SCENES:
            def expected_dynamic(actual, scene=scene):
                return scene_oracle(original,scene,[row[2]*100 for row in actual],rate)[0]
            report,actual = check(f'auto_dynamic_{scene}_{rate}',
                make_scene(scene,0,dynamic=True,diagnostic=True), dynamic_frames,rate,
                expected_dynamic,output_channels=3,updates=((.1,1),(.5,.5),(.8,0),(1.,.75)),
                update_target=SCENE_AMOUNT_TARGET)
            intensity = [row[2] for row in actual]
            step = max(abs(b-a) for a,b in zip(intensity,intensity[1:])) if intensity else math.inf
            report['maximum_amount_step'] = step
            report['passed'] &= (len(actual) == len(original) and intensity[-1] == .75 and
                step <= 1/(rate*.02)+1e-7 and min(intensity)==0 and max(intensity)==1 and
                all(row.get('attempts', [{}])[-1].get('reply_error')==0 for row in report.get('updates',[])) and
                len(report.get('updates',[])) == 4)
    # Exact 4096-block EOF is reachable in decoded HLS. Keep the old N+17 cases.
    frames = [(round(12000*math.sin(n*.23)), round(8000*math.sin(n*.17))) for n in range(49152)]
    check('auto_mono_aligned_neutral_96000', mono_auto_graph(0), frames, 96000,
          [[value/32768 for value in pair] for pair in frames], exact=True)
    # One native handle keeps the exact same graph across changing file formats.
    files = []
    for rate in (44100, 96000, 48000):
        frames = [(round(13000*math.sin(n*.23)), round(8000*math.sin(n*.17))) for n in range(rate//10+17)]
        source = args.output.parent/f'switch-{rate}.wav'
        write_wav(source,frames,rate)
        files.append(source.resolve())
    for label,base in [('mono',mono_auto_graph(1)),('rc',make_scene('telephone',100))]:
        expected=[]
        for source,rate in zip(files,(44100,96000,48000)):
            with wave.open(str(source)) as stream:
                original = [[v/32768 for v in pair] for pair in struct.iter_unpack('<hh',stream.readframes(stream.getnframes()))]
            values = mono_oracle(original,rate,1) if label=='mono' else scene_oracle(original,'telephone',100,rate)[0]
            expected.extend([(*pair,rate) for pair in values])
        graph = base.replace('[out]', '[effect]') + ";[effect]aeval='val(0)|val(1)|s':c=3.0,aformat=channel_layouts=3.0[out]"
        report,actual = check(f'auto_same_player_fs_{label}',graph,[],0,expected,output_channels=3,
            source_url=str(files[0]),actions=((.35,['loadfile',str(files[1]),'replace']),
            (.7,['loadfile',str(files[2]),'replace'])))
        report['observed_native_sample_rates'] = sorted(set(row[2] for row in actual))
        report['passed'] &= (report.get('initialized_handles')==1 and len(report.get('end_files',[]))==3 and
                            report['observed_native_sample_rates']==[44100,48000,96000])
    frames=combination_frames()+[(0,0)]*17
    nodes=[('eq',equalizer_graph([15]*10)),('mono',mono_auto_graph(1)),('headroom',LIMITER_GRAPH)]
    for scene in SCENES:
        graph=make_scene(scene,100 if scene=='telephone' else 0,dynamic=True)
        nodes.append((scene,graph))
    report,actual=run(args.output.parent,args.libmpv.resolve(),'auto_96k_cost','[in]anull[out]',
        frames,96000,timeout=30,af_chain=module_chain(nodes))
    report['frames']=len(actual)
    report['passed']=(report['process'].get('return_code')==0 and len(actual)==len(frames) and
        all(math.isfinite(v) for pair in actual for v in pair) and
        not any(x['level'] in ('error','fatal') for x in report.get('logs',[])))
    report['scope']='one reference offline CPU sample; EQ+15, mono1, limiter, all scenes resident, telephone1/others0; no sustained/device performance claim'
    checks.append(report)
    print('auto_96k_cost',report['passed'],report.get('timing'),flush=True)
    args.output.write_text(json.dumps({'gate_status':'incomplete',
        'rc_mode':'native_asendcmd_17g_required' if args.native_rc else 'expression',
        'checks':checks},indent=2),encoding='utf-8')
    raise SystemExit(0 if all(x['passed'] for x in checks) else 1)


if __name__ == '__main__':
    main()
