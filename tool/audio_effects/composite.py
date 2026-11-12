"""Exercise the real multi-module buffer path without joining recursive graphs."""

import math
from basic import equalizer_graph
from graphs import mono_graph, scene_graph


def module_chain(nodes):
    return ",".join(["format=channels=stereo"] + [
        f"@{name}:lavfi=o=[threads=1]:graph=%{len(graph.encode('utf-8'))}%{graph}"
        for name, graph in nodes
    ])


def full_combination():
    return module_chain([
        ("eq", equalizer_graph([15] * 10)),
        ("mono", mono_graph(96000).replace("volume@mono_amount=0:", "volume@mono_amount=1:")),
        ("scene", scene_graph("bathroom", 100, rate=96000)),
    ])


def combination_frames():
    return [
        (round((.7*math.sin(2*math.pi*440*n/96000)+.1*math.sin(2*math.pi*1733*n/96000))*32767),
         round((.6*math.sin(2*math.pi*880*n/96000)+.15*math.sin(2*math.pi*2199*n/96000))*32767))
        for n in range(384000)
    ]


def add_combination_case(case, require):
    frames = combination_frames()
    def assess(actual, _):
        peak = max(abs(value) for pair in actual for value in pair)
        clipped = sum(abs(value) == 1 for pair in actual for value in pair)
        require(peak == 1 and clipped > 0, "overdrive fixture did not exercise scene limiting")
        return {"peak": peak, "scene_clipped_samples": clipped,
                "modules": "EQ all +15 dB -> mono max -> bathroom 100%",
                "scope": "buffer/crash regression; not headroom or perceptual acceptance"}

    case("full_combination", "[in]anull[out]", frames, 96000, assess, af_chain=full_combination())
