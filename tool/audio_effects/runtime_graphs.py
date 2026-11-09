"""Resident native channel/guard modules, separate from the accepted baseline.

Use separate labeled mpv lavfi nodes, with format=channels=stereo at entry and
o=[threads=1]. Commands are ['af-command', node_label, 'volume', value, target].
Only on an actual -12 reply, retry the exact bare instance name after @.
No template rebuild or whole-AF toggle is needed for these runtime controls.
"""
from limiter import LIMITER

CHANNEL_MODE_TARGET = 'volume@channel_mode'
GUARD_MIX_TARGET = 'volume@guard_mix'
CHANNEL_MODES = ('normal', 'swap', 'clone_left', 'clone_right')


def channel_mode_graph(mode=0, diagnostic=False):
    """Control values 0 normal, 1 swap, 2 clone left, 3 clone right.

    Initialize both ear weights from the current native control. Each ear moves at
    1/(Fs*.02) per sample, without resetting history on subsequent commands.
    Diagnostic output: L, R, left-ear L weight, right-ear L weight, target mode.
    Exact weight endpoints copy the selected input rather than multiplying it.
    """
    desired = ('if(eq(val(2),0)+eq(val(2),2),1,0)',
               'if(eq(val(2),1)+eq(val(2),2),1,0)')

    def expression(target, audio):
        weight = (f'if(eq(n,0),st(0,{target});st(1,1/(s*.02)));'
                  f'st(0,ld(0)+clip(({target})-ld(0),-ld(1),ld(1)));')
        return weight + ("if(eq(ld(0),1),val(0),if(eq(ld(0),0),val(1),"
                         "val(0)*ld(0)+val(1)*(1-ld(0))))" if audio else 'ld(0)')

    expressions = [expression(desired[0], True),
                   expression(desired[1], True)]
    if diagnostic:
        expressions += [expression(desired[0], False),
                        expression(desired[1], False), 'val(2)']
    layout = '5.0' if diagnostic else 'stereo'
    return (
        '[in]aformat=sample_fmts=dblp:channel_layouts=stereo,asplit=2[audio][control];'
        f'[control]aeval=1:c=mono,volume@channel_mode={mode}:precision=double,'
        'aformat=sample_fmts=dblp:channel_layouts=mono[mode];'
        '[audio][mode]join=inputs=2:channel_layout=3.0:map=0.0-FL|0.1-FR|1.0-FC,'
        "aeval='" + '|'.join(expressions) + f"':c={layout},aformat=channel_layouts={layout}[out]"
    )


def warm_limiter_graph(enabled=False, diagnostic=False):
    """Guard control 0 selects exact dry, 1 selects the continuously warm limiter.

    Guard changes immediately; a crossfade could expose unbounded EQ output.
    Diagnostic output is L, R, sample-aligned guard selection. The limiter keeps
    latency compensation enabled even when its output is not selected.
    """
    expressions = 'if(val(4),val(2),val(0))|if(val(4),val(3),val(1))'
    if diagnostic:
        expressions += '|val(4)'
    layout = '3.0' if diagnostic else 'stereo'
    return (
        '[in]aformat=sample_fmts=dblp:channel_layouts=stereo,asplit=3[dry][work][control];'
        '[work]' + LIMITER + '[limited];'
        f'[control]aeval=1:c=mono,volume@guard_mix={int(enabled)}:precision=double,'
        'aformat=sample_fmts=dblp:channel_layouts=mono[amount];'
        '[dry][limited][amount]join=inputs=3:channel_layout=5.0:'
        'map=0.0-FL|0.1-FR|1.0-FC|1.1-BL|2.0-BR,'
        f"aeval='{expressions}':c={layout},aformat=channel_layouts={layout}[out]"
    )
