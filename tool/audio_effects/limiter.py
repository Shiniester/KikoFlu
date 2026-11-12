"""Sample-peak limiter contracts, separate from scene coloration and linear synthesis."""

import math
from basic import equalizer_graph
from graphs import mono_graph, scene_graph
from composite import module_chain, combination_frames

LIMITER = "alimiter=limit=0.97:attack=5:release=50:level=false:latency=true"
LIMITER_GRAPH = "[in]" + LIMITER + ",aformat=channel_layouts=stereo[out]"
HOT_GRAPH = "[in]aeval='val(ch)*4':c=same," + LIMITER + ",aformat=channel_layouts=stereo[out]"


def limited_nodes():
    return [
        ("eq", equalizer_graph([15] * 10)),
        ("mono", mono_graph(96000).replace("volume@mono_amount=0:", "volume@mono_amount=1:")),
        ("headroom", LIMITER_GRAPH),
    ]


def limited_prefix():
    return module_chain(limited_nodes())


def limited_combination():
    return module_chain(limited_nodes() + [("scene", scene_graph("bathroom", 100, rate=96000))])


def add_limiter_cases(case, require):
    for rate in (44100, 48000, 96000):
        frames = [(0,0)] * (rate//10 + 17)
        for n in (0, 1, len(frames)//2, len(frames)-1):
            frames[n] = (12000, -6000)

        def assess_low(actual, _, frames=frames):
            error = max(abs(x-y/32768) for a,b in zip(actual,frames) for x,y in zip(a,b))
            require(error == 0, "limiter changed low-level samples or impulse timing")
            return {"max_error": error, "first_last_impulses_preserved": True}

        case(f"limiter_{rate}_low", LIMITER_GRAPH, frames, rate, assess_low)
        short = [(0,0)] * (int(rate*.002) + 1)
        short[0] = (12000, -6000)
        short[-1] = (-6000, 3000)
        case(f"limiter_{rate}_short", LIMITER_GRAPH, short, rate,
             lambda a,r,frames=short: assess_low(a,r,frames))

        hot = []
        for n in range(rate//5 + 17):
            left = 2 * round(14000 * math.sin(2*math.pi*1000*n/rate))
            hot.append((left, left//2))

        def assess_hot(actual, _):
            peak = max(abs(v) for pair in actual for v in pair)
            require(.9 < peak <= .97+1e-7, "limiter sample peak exceeded the configured limit")
            ratio_error = max(abs(right-.5*left) for left,right in actual)
            require(ratio_error < 1e-7, "limiter changed linked stereo balance")
            return {"peak": peak, "limit": .97, "linked_channel_error": ratio_error}

        case(f"limiter_{rate}_hot", HOT_GRAPH, hot, rate, assess_hot)

    frames = combination_frames()

    def assess_prefix(actual, _):
        peak = max(abs(v) for pair in actual for v in pair)
        require(.9 < peak <= .97+1e-7, "pre-scene modular output exceeded the limiter threshold")
        return {"peak": peak, "limit": .97, "placement": "after EQ/mono, before scene"}

    case("limiter_modular_prefix", "[in]anull[out]", frames, 96000, assess_prefix,
         af_chain=limited_prefix())

    def assess_combined(actual, _):
        peak = max(abs(v) for pair in actual for v in pair)
        require(.01 < peak <= 1, "scene output is silent or outside its specified clipping range")
        return {"peak": peak, "limiter_placement": "before scene", "scene_intentional_clipping": True}

    case("limiter_full_combination", "[in]anull[out]", frames, 96000, assess_combined,
         af_chain=limited_combination())
