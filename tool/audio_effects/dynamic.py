"""Exercise real scene commands against sample-aligned native control observations."""

import math
from graphs import scene_dynamic_graph, scene_oracle


def add_dynamic_scene_cases(case, require):
    frames = [
        (round(.95 * math.sin(2*math.pi*1000*n/48000) * 32767),
         round(.8 * math.sin(2*math.pi*700*n/48000+.2) * 32767))
        for n in range(105617)
    ]
    original = [(l/32768, r/32768) for l,r in frames]
    updates = ((.3, 1), (.8, .5), (1.3, 0), (1.6, .75))
    for scene in ("bathroom", "through_wall", "telephone"):
        static_full, _ = scene_oracle(original, scene, 100)

        def assess(actual, report, scene=scene, static_full=static_full):
            require(len(report["updates"]) == 4, "not all scene commands were sent")
            require(all([5,0,100+n] in report["events"] for n in range(4)),
                    "scene af-command reply failed")
            require(sum(e[0] == 8 for e in report["events"]) == 1,
                    "scene command loaded media again")
            intensity = [row[2] for row in actual]
            require(min(intensity) == 0 and max(intensity) == 1 and intensity[-1] == .75,
                    "native scene targets were not reached")
            step = max(abs(b-a) for a,b in zip(intensity, intensity[1:]))
            require(step <= 1/960+1e-7, "scene amount exceeded the 20 ms full-scale slew")
            expected, clamps = scene_oracle(original, scene, [i*100 for i in intensity])
            error = max(abs(a[c]-e[c]) for a,e in zip(actual, expected) for c in (0,1))
            require(error < 1e-6, "dynamic scene differs from the time-varying Eara recurrence")
            zero_error = max(abs(a[c]-o[c]) for a,o in zip(actual, original)
                             if a[2] == 0 for c in (0,1))
            require(zero_error == 0, "zero scene amount changed original PCM")
            fade_error = max(abs(a[c]-((1-a[2])*o[c]+a[2]*full[c]))
                             for a,o,full in zip(actual, original, static_full) for c in (0,1))
            require(fade_error > 1e-3, "fixture must distinguish true parameter changes from fading full wet")
            if scene == "bathroom":
                require(clamps > 0, "dynamic bathroom must exercise feedback write clipping")
            return {"max_error": error, "zero_amount_error": zero_error,
                    "maximum_amount_step": step, "fade_only_max_error": fade_error,
                    "oracle_feedback_write_clips": clamps,
                    "diagnostic_channel": "native sample-aligned intensity, not audio"}

        case("scene_dynamic_" + scene, scene_dynamic_graph(scene, diagnostic=True),
             frames, 48000, assess, updates, output_channels=3,
             update_target="volume@scene_amount")
