"""Real HLS format-change prototype; parameter retention remains an explicit red contract."""
import argparse
import json
import math
from pathlib import Path
import subprocess

from adaptive_fs import (allpass_graph, allpass_oracle, mono_auto_graph,
                         mono_oracle, scene_auto_graph, SCENE_AMOUNT_TARGET)
from graphs import scene_oracle
from native import run, write_wav, probe


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libmpv', required=True, type=Path)
    parser.add_argument('--ffmpeg', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--native-rc', action='store_true',
                        help='use native biquad/asendcmd; requires the %%.17g build, no fallback')
    args = parser.parse_args()
    def make_scene(name, amount, **options):
        return scene_auto_graph(name, amount, native_rc=args.native_rc, **options)
    root = args.output.resolve().parent
    root.mkdir(parents=True, exist_ok=True)
    for index, rate in enumerate((44100, 96000)):
        frames = [(round(13000*math.sin(2*math.pi*800*n/rate)),
                   round(9000*math.sin(2*math.pi*1300*n/rate))) for n in range(rate//2)]
        source = root/f'{index}.wav'
        write_wav(source, frames, rate)
        subprocess.run([str(args.ffmpeg.resolve()), '-y', '-v', 'error', '-i', str(source),
                        '-c:a', 'aac', '-b:a', '192k', '-f', 'adts', str(root/f'{index}.aac')],
                       check=True, timeout=10)
    playlist = root/'switch.m3u8'
    playlist.write_text('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n'
        '#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:0.5,\n0.aac\n#EXT-X-DISCONTINUITY\n'
        '#EXTINF:0.5,\n1.aac\n#EXT-X-ENDLIST\n', encoding='utf-8')
    results = []
    baseline = []
    for name, base in [('bypass', '[in]anull[out]'), ('ap', allpass_graph()),
                       ('mono', mono_auto_graph(1)), ('telephone', make_scene('telephone',100)),
                       ('bathroom', make_scene('bathroom',100))]:
        graph = base.replace('[out]', '[effect]') + ";[effect]aeval='val(0)|val(1)|s':c=3.0,aformat=channel_layouts=3.0[out]"
        # The no-op volume action enables the existing capture append option, so
        # PCM AO reopening on Fs change cannot truncate the preceding segment.
        report, actual = run(root, args.libmpv.resolve(), 'hls_'+name, graph, [], 0,
            source_url=str(playlist), demuxer_format='hls', output_channels=3,
            actions=((0,['set','volume','100']),))
        report['frames'] = len(actual)
        report['ranges'] = [[n,row[2]] for n,row in enumerate(actual) if n==0 or row[2]!=actual[n-1][2]]
        report['passed'] = native_ok(report) and [row[1] for row in report['ranges']] == [44100,96000]
        if name == 'bypass':
            baseline = actual
        elif len(actual) == len(baseline) and report['passed']:
            expected = []
            for index,(start,rate) in enumerate(report['ranges']):
                end = report['ranges'][index+1][0] if index+1<len(report['ranges']) else len(actual)
                values = [row[:2] for row in baseline[start:end]]
                if name == 'ap':
                    output = allpass_oracle(values,int(rate))
                elif name == 'mono':
                    output = mono_oracle(values,int(rate),1)
                else:
                    output = scene_oracle(values,name,100,int(rate))[0]
                expected.extend(output)
            report['max_error'] = max(abs(a-b) for pair,ref in zip(actual,expected) for a,b in zip(pair[:2],ref))
            report['passed'] &= report['max_error'] < 1e-6
        else:
            report['passed'] = False
        results.append(report)
        print(name,report['passed'],report['frames'],report['ranges'],report.get('max_error'),flush=True)

    graph = make_scene('bathroom',0,dynamic=True,diagnostic=True).replace('[out]','[effect]')
    graph += ";[effect]aeval='val(0)|val(1)|val(2)|s|0':c=5.0,aformat=channel_layouts=5.0[out]"
    report, actual = run(root,args.libmpv.resolve(),'hls_runtime_parameter_retention',graph,[],0,
        source_url=str(playlist),demuxer_format='hls',output_channels=5,
        updates=((.1,1),),update_target=SCENE_AMOUNT_TARGET,actions=((0,['set','volume','100']),))
    report['frames'] = len(actual)
    report['amount_by_native_fs'] = {str(fs): {
        'min': min(row[2] for row in actual if row[3]==fs),
        'max': max(row[2] for row in actual if row[3]==fs),
        'last': [row[2] for row in actual if row[3]==fs][-1]
    } for fs in sorted(set(row[3] for row in actual))}
    report['passed'] = (native_ok(report) and set(report['amount_by_native_fs'])=={'44100.0','96000.0'} and
        all(value['last']==1 for value in report['amount_by_native_fs'].values()) and
        len(report['updates'])==1 and report['updates'][0]['attempts'][-1].get('reply_error')==0)
    report['max_error'] = dynamic_error(actual,baseline)
    report['reason'] = 'An amount set by af-command must survive native input-format reinitialization'
    results.append(report)
    print('parameter_retention',report['passed'],report['amount_by_native_fs'],flush=True)
    report,audio = run(root,args.libmpv.resolve(),'hls_audio_reconfig_resend',graph,[],0,
        source_url=str(playlist),demuxer_format='hls',output_channels=5,
        updates=((.1,1),),update_target=SCENE_AMOUNT_TARGET,actions=((0,['set','volume','100']),),
        reconfig_actions=((96000,['af-command','effects','volume','1',SCENE_AMOUNT_TARGET]),))
    changed = [row for row in audio if row[3]==96000]
    metrics = {'total_frames':len(audio),'new_fs_frames':len(changed),
        'initial_zero_amount_frames':next((n for n,row in enumerate(changed) if row[2]>0),len(changed)),
        'first_full_amount_frame':next((n for n,row in enumerate(changed) if row[2]==1),None),
        'last_amount':changed[-1][2] if changed else None}
    report['frames'] = metrics['total_frames']
    report['boundary'] = report.get('audio_reconfigs',[]) + [metrics]
    commands = [row for row in report.get('actions',[]) if row.get('on_audio_reconfig')==96000]
    report['passed'] = (native_ok(report) and metrics['total_frames']==len(baseline) and
        metrics['last_amount']==1 and len(commands)==1 and commands[0].get('reply_error')==0)
    report['max_error'] = dynamic_error(audio,baseline)
    report['passed'] &= report['max_error'] < 1e-6
    report['scope'] = ('native event resend candidate with 128-sample arealtime test pacing; '
        'initial zero samples and the subsequent 20ms ramp are recorded; '
        'this is not a production scheduling-latency bound')
    results.append(report)
    print('audio_reconfig_resend',report['passed'],metrics,flush=True)
    args.output.write_text(json.dumps({'gate_status':'incomplete',
        'rc_mode':'native_asendcmd_17g_required' if args.native_rc else 'expression',
        'source':'self-generated AAC HLS with a declared discontinuity and no native error logs',
        'checks':results},indent=2),encoding='utf-8')
    raise SystemExit(0 if all(row['passed'] for row in results) else 1)



def dynamic_error(actual, baseline):
    if len(actual)!=len(baseline):
        return math.inf
    error=0
    boundaries=[n for n,row in enumerate(actual) if n==0 or row[3]!=actual[n-1][3]]+[len(actual)]
    for start,end in zip(boundaries,boundaries[1:]):
        expected=scene_oracle([row[:2] for row in baseline[start:end]],'bathroom',
            [row[2]*100 for row in actual[start:end]],int(actual[start][3]))[0]
        error=max(error,max(abs(a-b) for pair,ref in zip(actual[start:end],expected) for a,b in zip(pair[:2],ref)))
    return error

def native_ok(report):
    return (report['process'].get('return_code')==0 and
        report.get('end_file')=={'reason':0,'error':0} and
        report.get('initialized_handles')==1 and
        sum(row[0]==probe.FILE_LOADED for row in report.get('events',[]))==1 and
        not any(row['level'] in ('error','fatal') for row in report.get('logs',[])))



if __name__ == '__main__':
    main()
