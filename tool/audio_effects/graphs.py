"""Test-only lavfi prototypes and independent Eara recurrence oracle."""
import math

# Fixed Eara profile values; independently assembled filtergraphs below.
SCENES = {
    "bathroom": dict(dry=.58, direct=.30, reflection=.72, feedback=.52,
                     mono=.20, width=.88, hp=180, hp_stages=1, lp=6400,
                     lp_stages=1, gain=.90, drive=0,
                     taps=((16,.32),(27,.28),(41,.23),(63,.18),(96,.12))),
    "through_wall": dict(dry=.03, direct=1.02, reflection=.16, feedback=.20,
                         mono=.68, width=.18, hp=120, hp_stages=1, lp=1200,
                         lp_stages=3, gain=1, drive=0,
                         taps=((14,.10),(24,.07),(39,.05))),
    "telephone": dict(dry=0, direct=1.08, reflection=0, feedback=0,
                       mono=1, width=0, hp=430, hp_stages=3, lp=2850,
                       lp_stages=3, gain=1.06, drive=.34, taps=()),
}


def scene_parameters(name, amount):
    profile = SCENES[name]
    i = amount / 100
    boost = 1 + .45 * i * i
    blend = min(i * (1 + .2 * i), 1)
    return dict(
        dry=max(0, min(1, 1 + (profile["dry"] - 1) * blend)),
        direct=profile["direct"] * i * boost,
        reflection=profile["reflection"] * i * boost,
        feedback=max(0, min(.88, profile["feedback"] * i * boost)),
        width=max(0, min(1.25, 1 + (profile["width"] - 1) * blend)) *
              (1 - max(0, min(1, profile["mono"] * i * boost))),
        gain=1 + (profile["gain"] - 1) * i,
        drive=profile["drive"] * i * boost,
    )


def rc(cutoff, rate, high):
    cutoff = max(10, min(rate * .45, cutoff))
    dt = 1 / rate
    tau = 1 / (2 * math.pi * cutoff)
    return max(.0001, min(.9999 if high else 1, tau / (tau + dt) if high else dt / (tau + dt)))


def scene_graph(name, amount, rate=48000, chunk=128):
    if amount == 0:
        return "[in]anull[out]"
    profile = SCENES[name]
    p = scene_parameters(name, amount)
    near = (1 + p["width"]) / 2
    far = (1 - p["width"]) / 2
    filters = []
    for high, key in ((True, "hp"), (False, "lp")):
        alpha = rc(profile[key], rate, high)
        for _ in range(profile[key + "_stages"]):
            b1, a1 = (-alpha, -alpha) if high else (0, alpha - 1)
            filters.append(f"biquad=b0={alpha}:b1={b1}:b2=0:a0=1:a1={a1}:a2=0:precision=f64")
    graph = (
        "[in]aformat=sample_fmts=dblp:channel_layouts=stereo,asplit=2[dry][raw];"
        f"[raw]pan=stereo|c0={near}*c0+{far}*c1|c1={far}*c0+{near}*c1,"
        + ",".join(filters)
    )
    taps = profile["taps"]
    if taps:
        delay = max(1, taps[-1][0] * rate // 1000)
        graph += (
            ",asplit=2[direct][filtered];"
            f"anullsrc=r={rate}:cl=stereo,atrim=end_sample={delay},aformat=sample_fmts=dblp,"
            f"asetnsamples=n={chunk}:p=0,asetpts=N/SR/TB[seed];"
            "[seed][fb]concat=n=2:v=0:a=1[delayed];"
            f"[filtered]asetnsamples=n={chunk}:p=0,asetpts=N/SR/TB[f];"
            "[f][delayed]amix=inputs=2:normalize=0:duration=first,"
            "aeval='clip(val(ch),-1.25,1.25)':c=same,"
            f"asplit={len(taps)+1}[write]" + "".join(f"[t{n}]" for n in range(len(taps))) + ";"
            f"[write]aeval='val(ch)*{p['feedback']}':c=same[fb];"
        )
        for n, (ms, gain) in enumerate(taps):
            graph += f"[t{n}]adelay={max(1,ms*rate//1000)}S:all=1,aeval='val(ch)*{gain}':c=same[q{n}];"
        graph += "".join(f"[q{n}]" for n in range(len(taps)))
        graph += f"amix=inputs={len(taps)}:normalize=0[reflection];"
        graph += "[dry][direct][reflection]amix=inputs=3:normalize=0:duration=first:"
        graph += f"weights='{p['dry']*p['gain']} {p['direct']*p['gain']} {p['reflection']*p['gain']}',"
    else:
        graph += "[filtered];[dry][filtered]amix=inputs=2:normalize=0:duration=first:"
        graph += f"weights='{p['dry']*p['gain']} {p['direct']*p['gain']}',"
    if p["drive"]:
        scale = 1 + 4 * p["drive"]
        graph += f"aeval='clip(tanh(clip(val(ch)*{scale},-8,8))/{math.tanh(scale)},-1,1)':c=same,aformat=channel_layouts=stereo[out]"
    else:
        graph += "aeval='clip(val(ch),-1,1)':c=same,aformat=channel_layouts=stereo[out]"
    return graph


def scene_dynamic_graph(name, rate=48000, diagnostic=False):
    profile = SCENES[name]
    taps = profile["taps"]
    control_outputs = ["pre", "mix"] + (["feedback"] if taps else []) + (["observe"] if diagnostic else [])
    graph = (
        "[in]aformat=sample_fmts=dblp:channel_layouts=stereo,"
        # Pad only the processing loop; the unpadded dry input bounds final output.
        "asplit=2[dry][work];[work]asetnsamples=n=128:p=1,"
        "asetpts=N/SR/TB,asplit=2[raw][control];"
        "[control]aeval=1:c=mono,volume@scene_amount=0:precision=double,"
        "aformat=sample_fmts=dblp:channel_layouts=mono,"
        "aeval='st(0,ld(0)+clip(val(0)-ld(0),-1/(s*.02),1/(s*.02)));ld(0)':c=mono,"
        "aformat=sample_fmts=dblp:channel_layouts=mono,"
        f"asplit={len(control_outputs)}" + "".join(f"[i_{label}]" for label in control_outputs) + ";"
        "[raw][i_pre]join=inputs=2:channel_layout=3.0:map=0.0-FL|0.1-FR|1.0-FC[pre];"
    )
    # Zero amount keeps RC/reflection histories warm while skipping per-sample parameter math.
    source = []
    for channel in (0, 1):
        source.append(
            f"if(val(2),st(0,val(2));st(1,ld(0)*(1+.45*ld(0)*ld(0)));"
            "st(2,min(1,ld(0)*(1+.2*ld(0))));"
            f"st(3,(1+({profile['width']}-1)*ld(2))*(1-min(1,{profile['mono']}*ld(1))));"
            f"(val(0)+val(1))/2+(val({channel})-(val(0)+val(1))/2)*ld(3),val({channel}))"
        )
    graph += "[pre]aeval='" + "|".join(source) + "':c=stereo,aformat=sample_fmts=dblp:channel_layouts=stereo,"
    filters = []
    for high, key in ((True, "hp"), (False, "lp")):
        alpha = rc(profile[key], rate, high)
        for _ in range(profile[key + "_stages"]):
            b1, a1 = (-alpha, -alpha) if high else (0, alpha-1)
            filters.append(f"biquad=b0={alpha}:b1={b1}:b2=0:a0=1:a1={a1}:a2=0:precision=f64")
    graph += ",".join(filters)
    if taps:
        delay = max(1, taps[-1][0]*rate//1000)
        graph += (
            ",asplit=2[direct][filtered];"
            f"anullsrc=r={rate}:cl=stereo,atrim=end_sample={delay},aformat=sample_fmts=dblp,"
            "asetnsamples=n=128:p=0,asetpts=N/SR/TB[seed];"
            "[seed][fb]concat=n=2:v=0:a=1, aformat=sample_fmts=dblp:channel_layouts=stereo[delayed];"
            "[delayed][filtered][i_feedback]join=inputs=3:channel_layout=5.0:"
            "map=0.0-FL|0.1-FR|1.0-FC|1.1-BL|2.0-BR[recurrence];"
        )
        write = [
            f"if(val(4),clip(val({channel+2})+min(.88,{profile['feedback']}*val(4)*(1+.45*val(4)*val(4)))*val({channel}),-1.25,1.25),clip(val({channel+2}),-1.25,1.25))"
            for channel in (0, 1)
        ]
        graph += "[recurrence]aeval='" + "|".join(write) + "':c=stereo,aformat=sample_fmts=dblp:channel_layouts=stereo,"
        graph += f"asplit={len(taps)+1}[fb]" + "".join(f"[t{n}]" for n in range(len(taps))) + ";"
        for n,(ms,gain) in enumerate(taps):
            graph += f"[t{n}]adelay={max(1,ms*rate//1000)}S:all=1,aeval='val(ch)*{gain}':c=same[q{n}];"
        graph += "".join(f"[q{n}]" for n in range(len(taps)))
        graph += f"amix=inputs={len(taps)}:normalize=0[reflection];"
        graph += (
            "[dry][direct][reflection][i_mix]join=inputs=4:channel_layout=6.1:"
            "map=0.0-FL|0.1-FR|1.0-FC|1.1-LFE|2.0-BC|2.1-SL|3.0-SR[final];"
        )
        intensity_channel = 6
    else:
        graph += "[filtered];[dry][filtered][i_mix]join=inputs=3:channel_layout=5.0:"
        graph += "map=0.0-FL|0.1-FR|1.0-FC|1.1-BL|2.0-BR[final];"
        intensity_channel = 4
    expressions = []
    for channel in (0, 1):
        reflection = f"+{profile['reflection']}*ld(1)*val({channel+4})" if taps else ""
        expressions.append(
            f"if(val({intensity_channel}),st(0,val({intensity_channel}));st(1,ld(0)*(1+.45*ld(0)*ld(0)));"
            "st(2,min(1,ld(0)*(1+.2*ld(0))));"
            f"st(3,(1+({profile['gain']}-1)*ld(0))*"
            f"((1+({profile['dry']}-1)*ld(2))*val({channel})+"
            f"{profile['direct']}*ld(1)*val({channel+2}){reflection}));"
            f"st(4,{profile['drive']}*ld(1));"
            f"clip(if(gt(ld(4),0),tanh(clip(ld(3)*(1+4*ld(4)),-8,8))/tanh(1+4*ld(4)),ld(3)),-1,1),val({channel}))"
        )
    graph += "[final]aeval='" + "|".join(expressions) + "':c=stereo"
    if diagnostic:
        graph += ",aformat=sample_fmts=dblp:channel_layouts=stereo[effect];[effect][i_observe]join=inputs=2:channel_layout=3.0:"
        graph += "map=0.0-FL|0.1-FR|1.0-FC,aformat=channel_layouts=3.0[out]"
    else:
        graph += ",aformat=channel_layouts=stereo[out]"
    return graph


def scene_oracle(frames, name, amount, rate=48000):
    if amount == 0:
        return frames, 0
    profile = SCENES[name]
    def parameters(percent):
        intensity = percent / 100
        wet = intensity * (1 + .45 * intensity**2)
        blend = min(1, intensity + .2*intensity**2)
        return {
            "dry": max(0, min(1, 1-(1-profile["dry"])*blend)),
            "direct": profile["direct"]*wet,
            "reflection": profile["reflection"]*wet,
            "feedback": min(.88, profile["feedback"]*wet),
            "width": max(0, min(1.25, 1+(profile["width"]-1)*blend)) *
                     (1-min(1, profile["mono"]*wet)),
            "gain": 1+(profile["gain"]-1)*intensity,
            "drive": profile["drive"]*wet,
        }
    varying = isinstance(amount, list)
    p = None if varying else parameters(amount)
    hp = rc(profile["hp"], rate, True)
    lp = rc(profile["lp"], rate, False)
    hp_inputs = [[0.0, 0.0] for _ in range(profile["hp_stages"])]
    hp_outputs = [[0.0, 0.0] for _ in range(profile["hp_stages"])]
    lp_outputs = [[0.0, 0.0] for _ in range(profile["lp_stages"])]
    taps = [(max(1, ms*rate//1000), gain) for ms,gain in profile["taps"]]
    delay = taps[-1][0] if taps else 0
    history, result = [], []
    clamps = 0
    for n, pair in enumerate(frames):
        if varying:
            p = parameters(amount[n])
        mid = sum(pair) / 2
        written, output = [], []
        for channel in (0, 1):
            sample = mid + (pair[channel] - mid) * p["width"]
            for stage in range(profile["hp_stages"]):
                value = hp * (hp_outputs[stage][channel] + sample - hp_inputs[stage][channel])
                hp_inputs[stage][channel] = sample
                hp_outputs[stage][channel] = value
                sample = value
            for stage in range(profile["lp_stages"]):
                sample = lp_outputs[stage][channel] + lp*(sample-lp_outputs[stage][channel])
                lp_outputs[stage][channel] = sample
            feedback = history[n-delay][channel] if delay and n >= delay else 0
            value = sample + p["feedback"] * feedback
            clamps += abs(value) > 1.25
            written.append(max(-1.25, min(1.25, value)))
            reflection = sum(gain*history[n-d][channel] for d,gain in taps if n >= d)
            value = p["gain"] * (p["dry"]*pair[channel] + p["direct"]*sample + p["reflection"]*reflection)
            if p["drive"]:
                scale = 1 + 4*p["drive"]
                value = math.tanh(max(-8, min(8, value*scale))) / math.tanh(scale)
            output.append(max(-1, min(1, value)))
        history.append(written)
        result.append(output)
    return result, clamps

def mono_graph(Fs):
    def ap(ms, g):
        D = max(1, int(Fs * ms / 1000 + .5))
        B = ' '.join(map(str, [g] + [0] * (D - 1) + [1]))
        A = ' '.join(map(str, [1] + [0] * (D - 1) + [g]))
        return f"aiir=f=tf:r=d:e=dbl:n=0:dry=1:wet=1:k=1:mix=1:z='{B}':p='{A}'"

    aps = ','.join(ap(ms,g) for ms,g in [(0.7,.5),(1.1,-.5),(1.7,.5)])
    # 0: smoothed amount; 1: direct peak; 2: slow envelope;
    # 3: onset strength; 4: onset suppression; 5: difference peak.
    expr = (
        "st(0,ld(0)+clip(val(2)-ld(0),-1/(s*.02),1/(s*.02)));"
        "st(1,max(abs(val(0)),ld(1)*exp(-1/(s*.003))));"
        "st(3,clip((abs(val(0))-2*ld(2))/(abs(val(0))+1e-12),0,1));"
        "st(2,ld(2)+(abs(val(0))-ld(2))*(1-exp(-1/(s*.02))));"
        "st(4,max(ld(3),ld(4)*exp(-1/(s*.01))));"
        "st(5,max(abs(val(1)-val(0)),ld(5)*exp(-1/(s*.003))));"
        ".5*(val(1)-val(0))*ld(0)*(1-ld(4))*min(1,ld(1)/(ld(5)+1e-12))"
    )
    return (
        "[in]aformat=sample_fmts=dblp:channel_layouts=stereo,asplit=3[dry][mid][ctl];"
        "[mid]pan=mono|c0=.5*c0+.5*c1,asplit=2[m][api];"
        f"[api]{aps}[ap];"
        "[ctl]aeval=1:c=mono,volume@mono_amount=0:precision=double,aformat=sample_fmts=dblp:channel_layouts=mono[target];"
        "[m][ap][target]join=inputs=3:channel_layout=3.0:map=0.0-FL|1.0-FR|2.0-FC[pack];"
        f"[pack]aeval='{expr}':c=mono,aformat=sample_fmts=dblp:channel_layouts=mono[side];"
        "[dry][side]join=inputs=2:channel_layout=3.0:map=0.0-FL|0.1-FR|1.0-FC[sum];"
        "[sum]aeval='val(0)+val(2)|val(1)-val(2)':c=stereo,aformat=channel_layouts=stereo[out]"
    )
