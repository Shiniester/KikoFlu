"""Resident widening from the validated actual-Fs allpass and linear M/S stages."""
from adaptive_fs import mono_auto_graph, MONO_AMOUNT_TARGET
from runtime_graphs import warm_limiter_graph

STEREO_AMOUNT_TARGET = 'volume@stereo_amount'


def binaural_graph(stereo_amount=0, mono_amount=0):
    """Fade the old mode to neutral before increasing the other, in native samples.

    Both targets use 0..1. Stereo width is 1+amount; mono adds only a difference
    derived from common content and preserves the input's existing difference.
    """
    graph = mono_auto_graph(mono_amount)
    start = graph.index('[ctl]apad=')
    end = graph.index('[target];', start) + len('[target];')
    transition = (
        'if(eq(n,0),st(4,1/(s*.02)));'
        'st(2,if(gt(ld(1),0),0,val(0)));'
        'st(3,if(gt(ld(0),0),0,val(1)));'
        'st(0,ld(0)+clip(ld(2)-ld(0),-ld(4),ld(4)));'
        'st(1,ld(1)+clip(ld(3)-ld(1),-ld(4),ld(4)));'
    )
    control = (
        '[ctl]apad=pad_len=1,asetnsamples=n=4096:p=1,aeval=1:c=mono,'
        'asplit=2[st_target][mo_target];'
        f'[st_target]{STEREO_AMOUNT_TARGET}={stereo_amount}:precision=double,'
        'aformat=sample_fmts=dblp:channel_layouts=mono[st];'
        f'[mo_target]{MONO_AMOUNT_TARGET}={mono_amount}:precision=double,'
        'aformat=sample_fmts=dblp:channel_layouts=mono[mo];'
        '[st][mo]join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR,'
        "aeval='" + transition + 'ld(0)|' + transition + "ld(1)':c=stereo,"
        'aformat=sample_fmts=dblp:channel_layouts=stereo,asplit=3[sw][mw][aw];'
        '[sw]pan=mono|c0=c0[width];[mw]pan=mono|c0=c1[target];'
        "[aw]aeval='max(val(0),val(1))':c=mono,aformat=sample_fmts=dblp:channel_layouts=mono[active];"
    )
    graph = graph[:start] + control + graph[end:]
    # Smoothing is shared by the two modes; allpass/envelope protection is unchanged.
    graph = graph.replace('st(0,ld(0)+clip(val(2)-ld(0),-ld(9),ld(9)));', 'st(0,val(2));')
    graph = graph.replace('[dry][side]join=inputs=2:channel_layout=3.0:map=0.0-FL|0.1-FR|1.0-FC[sum]',
        '[dry][side][width][active]join=inputs=4:channel_layout=5.0:map=0.0-FL|0.1-FR|1.0-FC|2.0-BL|3.0-BR[sum]')
    graph = graph.replace("aeval='val(0)+val(2)|val(1)-val(2)'",
        "aeval='val(0)+(val(0)-val(1))/2*val(3)+val(2)|val(1)-(val(0)-val(1))/2*val(3)-val(2)|val(4)'")
    return graph.replace("':c=stereo,aformat=channel_layouts=stereo[out]", "':c=3.0,aformat=channel_layouts=3.0[out]")


def binaural_guard_graph():
    """Select the warm limiter until the actual widening samples reach neutral.

    The third input channel carries only the aligned native amount envelope.
    It never reaches audio output. The existing guard target also covers EQ.
    """
    graph = warm_limiter_graph()
    graph = graph.replace('[in]aformat=sample_fmts=dblp:channel_layouts=stereo,asplit=3[dry][work][control];',
        '[in]aformat=sample_fmts=dblp:channel_layouts=3.0,asplit=2[audio][state];'
        '[state]pan=mono|c0=c2[active];'
        '[audio]pan=stereo|c0=c0|c1=c1,asplit=3[dry][work][control];')
    graph = graph.replace('[dry][limited][amount]join=inputs=3:channel_layout=5.0:map=0.0-FL|0.1-FR|1.0-FC|1.1-BL|2.0-BR,',
        '[dry][limited][amount][active]join=inputs=4:channel_layout=5.1:map=0.0-FL|0.1-FR|1.0-FC|1.1-LFE|2.0-BL|3.0-BR,')
    return graph.replace('if(val(4),val(2),val(0))|if(val(4),val(3),val(1))',
        'if(val(4)+val(5),val(2),val(0))|if(val(4)+val(5),val(3),val(1))')
