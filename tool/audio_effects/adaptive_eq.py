"""One-octave EQ template with native actual-Fs frequency selection.

Band levels follow the KikoFlu ASMR tuning in ADR 0011, derived from the fixed
Eara source 3918b196390011b0fccbab59e3489f72e96c92e9. The filtergraph and
validation oracle are independent. This does not replace the accepted Q=1
baseline. No production player is registered by this module.
"""
from basic import EQ_FREQUENCIES

EQ_TARGETS = tuple(f'equalizer@eq_band{band}' for band in range(10))
EQ_PRESETS = {
    'flat': (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    'bright': (-3.5, -2.5, -2, -1, -1, 0, 1, 2.5, 4.5, 3.5),
    'bassBoost': (4.5, 4.5, 3, 2.5, 1.5, 0, 0, -2.5, -3.5, -5.5),
    'tappingCrisp': (-4.5, -2.5, -2.5, -2, -1, 1, 2.5, 5.5, 4.5, 1),
    'tappingDull': (2.5, 3.5, 4.5, 3.5, 2, -2, -2.5, -4.5, -6.5, -10),
    'vocal': (-3.5, -2, -2, 0, 1, 4.5, 6.5, 2.5, 0, -4.5),
}


def equalizer_auto_graph(gains):
    """Ten resident native bands; gains are a ten-element snapshot in dB.

    Commands use ['af-command', module_label, 'g' or 'enable', value, EQ_TARGETS[i]].
    Retry only an actual -12 with the exact bare instance name after @.
    A zero gain must also use enable=0 for exact bypass; g=0 alone retains IIR
    roundoff. Smooth transitions and audio-reconfig resends belong to the caller's
    runtime contract, not to hot replacement of this graph.

    Start every filter at valid 10 Hz, then select max(10,min(nominal,Fs*.45))
    before its first input frame. Original dry is the timestamp/length anchor;
    only work uses the first-frame N+1 clock. The one-octave width is t=o:w=1.
    """
    commands, filters = [], []
    for target, frequency, gain in zip(EQ_TARGETS, EQ_FREQUENCIES, gains, strict=True):
        argument = f'max(10,min({frequency},.45*PTS/T))'.replace(',', r'\\,')
        for alias in (target, target.split('@', 1)[1]):
            commands.append(f'[enter+expr] {alias} f {argument}')
        filters.append(f'{target}=f=10:t=o:w=1:g={gain}:precision=f64:enable={int(gain != 0)}')
    return (
        '[in]aformat=sample_fmts=dblp:channel_layouts=stereo,asplit=2[dry][work];'
        "[work]asettb=expr=1/sr,asetpts=N+1,asendcmd=c='0.0-0.001 " + ', '.join(commands) +
        ";',asetpts=PTS-1," + ','.join(filters) + '[eq];'
        '[dry][eq]join=inputs=2:channel_layout=4.0:map=0.0-FL|0.1-FR|1.0-FC|1.1-BC,'
        "aeval='val(2)|val(3)':c=stereo,aformat=channel_layouts=stereo[out]"
    )
