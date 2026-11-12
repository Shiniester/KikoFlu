"""Switch independent dynamic scene nodes through neutral without media reload."""

import math
from composite import module_chain
from graphs import scene_dynamic_graph, scene_oracle

SCENES = ("bathroom", "through_wall", "telephone")
MODE_ACTIONS = ((.3, "bathroom", 1), (.7, "bathroom", 0),
                (.9, "through_wall", .5), (1.3, "through_wall", 0),
                (1.5, "telephone", .75), (1.9, "telephone", 0),
                (2.1, "bathroom", 1))


def mode_frames():
    # Leave one second of observable audio after the last command traverses all nodes.
    return [(round(.7*math.sin(2*math.pi*440*n/48000)*32767),
             round(.6*math.sin(2*math.pi*700*n/48000+.2)*32767)) for n in range(163217)]


def mode_chain():
    nodes = []
    for index, name in enumerate(SCENES):
        graph = scene_dynamic_graph(name, diagnostic=True)
        if index:
            prior_layout = "mono" if index == 1 else "stereo"
            result_layout = "4.0" if index == 1 else "5.0"
            prior = "|".join(f"val({n+2})" for n in range(index))
            mapping = "1.0-FL|1.1-FR|0.0-FC|1.2-BC" if index == 1 else "1.0-FL|1.1-FR|0.0-FC|0.1-BL|1.2-BR"
            # The original history drives join length; padded work avoids FFmpeg 6 EOF truncation.
            graph = ("[in]asplit=2[history][sound];"
                     f"[history]aeval='{prior}':c={prior_layout},aformat=channel_layouts={prior_layout}[prior];"
                     "[sound]asetnsamples=n=128:p=1,aeval='val(0)|val(1)':c=stereo,aformat=channel_layouts=stereo[scene_in];" +
                     graph.replace("[in]", "[scene_in]", 1).replace("[out]", "[scene_out]") +
                     f";[prior][scene_out]join=inputs=2:channel_layout={result_layout}:map={mapping},"
                     f"aformat=channel_layouts={result_layout}[out]")
        nodes.append((name, graph))
    return module_chain(nodes)


def add_mode_case(case, require):
    frames = mode_frames()
    commands = tuple((when, ["af-command", scene, "volume", str(amount), "volume@scene_amount"])
                     for when, scene, amount in MODE_ACTIONS)

    def assess(actual, report):
        actions = report.get("actions", [])
        require(len(actions) == len(commands), "not all scene mode commands were sent")
        require(all(a.get("enqueue_code") == 0 and a.get("reply_error") == 0 for a in actions),
                "scene mode command failed")
        require(sum(e[0] == 8 for e in report["events"]) == 1, "scene mode switch reloaded media")
        require(len(report.get("end_files", [])) == 1, "scene mode switch ended or sought media")
        controls = [[row[n+2] for row in actual] for n in range(3)]
        expected = [(l/32768, r/32768) for l,r in frames]
        steps = []
        for name, intensity, target in zip(SCENES, controls, (1, .5, .75)):
            require(min(intensity) == 0 and max(intensity) == target, "saved scene strength was not reached")
            step = max(abs(b-a) for a,b in zip(intensity,intensity[1:]))
            require(step <= 1/960+1e-7, "mode switch exceeded the 20 ms full-scale slew")
            steps.append(step)
            expected, _ = scene_oracle(expected, name, [value*100 for value in intensity])
        require(controls[0][-1] == 1 and controls[1][-1] == 0 and controls[2][-1] == 0,
                "returning to bathroom did not restore its saved strength")
        require(all(sum(value > 0 for value in row[2:]) <= 1 for row in actual),
                "scene modes overlapped instead of passing through neutral")
        error = max(abs(row[c]-wanted[c]) for row,wanted in zip(actual,expected) for c in (0,1))
        require(error < 1e-6, "mode output differs from the serial time-varying Eara recurrence")
        neutral = [(row,original) for row,original in zip(actual,frames) if not any(row[2:])]
        neutral_error = max(abs(row[c]-original[c]/32768) for row,original in neutral for c in (0,1))
        require(neutral_error == 0, "neutral bridge changed original samples")
        return {"max_error": error, "neutral_max_error": neutral_error,
                "maximum_amount_steps": steps, "neutral_frames": len(neutral),
                "diagnostic_channels": "sample-aligned bathroom/through-wall/telephone intensity",
                "scope": "native mode transition; app state persistence and CPU acceptance remain separate"}

    case("scene_modes", "[in]anull[out]", frames, 48000, assess,
         af_chain=mode_chain(), actions=commands, output_channels=5)
