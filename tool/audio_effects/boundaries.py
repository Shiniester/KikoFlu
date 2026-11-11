"""Playback boundaries compared with fresh native contexts, including decoder preroll."""

import math
from graphs import mono_graph, scene_dynamic_graph, scene_graph, scene_oracle


def boundary_frames():
    return [
        (round((.2*math.sin(2*math.pi*440*n/48000)+.1*math.sin(2*math.pi*1733*n/48000))*32767),
         round((.15*math.sin(2*math.pi*700*n/48000)+.05*math.sin(2*math.pi*1000*n/48000+.2))*32767))
        for n in range(144017)
    ]


def add_boundary_cases(case, require):
    frames = boundary_frames()
    mono = mono_graph(48000).replace("volume@mono_amount=0:", "volume@mono_amount=1:")
    scene = scene_dynamic_graph("bathroom").replace("volume@scene_amount=0:", "volume@scene_amount=1:")
    references = {}

    def record(name, actual):
        require(0 < len(actual) <= len(frames), "native boundary baseline is empty or too long")
        require(max(abs(v) for pair in actual for v in pair) > .01, "native baseline is silent")
        references[name] = actual
        return {"frames": len(actual), "reference": "fresh native context"}

    case("boundary_mono_reference", mono, frames, 48000,
         lambda a,r: record("mono_full", a))
    for name, graph in (("mono", mono), ("scene", scene)):
        # An exact seek decodes preroll before trimming. A physically sliced WAV
        # would start DSP history at a different point and is not this contract.
        # Match the seek capture's test clock so both outputs have the same framing.
        case("boundary_" + name + "_start_reference", graph, frames, 48000,
             lambda a,r,name=name: record(name + "_start", a),
             start_position=2, expect_full_input=False, pace_input=True)

    def actions_ok(report, count):
        actions = report.get("actions", [])
        require(len(actions) == count, "not all boundary actions ran")
        require(report.get("action_anchor_pcm_bytes", 0) > 0,
                "boundary clock started before actual PCM output")
        require(all(a.get("enqueue_code") == 0 and a.get("reply_error") == 0 for a in actions),
                "native boundary command failed")

    def assess_pause(actual, report):
        actions_ok(report, 2)
        require(report["actions"][0]["pause_after_reply"] == "yes" and
                report["actions"][1]["pause_after_reply"] == "no", "native pause state did not change")
        events = report["events"]
        require(events.index([5, 0, 1000]) < next(n for n,e in enumerate(events) if e[0] == 7),
                "pause was only acknowledged after EOF")
        require("mono_full" in references, "unpaused reference failed")
        error = max(abs(x-y) for a,b in zip(actual,references["mono_full"]) for x,y in zip(a,b))
        require(error == 0, "pause/resume dropped samples or reset processing history")
        return {"max_error": error, "frames": len(actual), "native_pause_acknowledged": True}

    case("boundary_pause_resume", mono, frames, 48000, assess_pause,
         actions=((.25, ["set", "pause", "yes"]), (.5, ["set", "pause", "no"])),
         actions_after_output=True)

    original = [(l/32768, r/32768) for l,r in frames]
    scene_full, _ = scene_oracle(original, "bathroom", [min(1, (n+1)/960)*100 for n in range(len(frames))])
    for name, graph in (("mono", mono), ("scene", scene)):
        def assess_seek(actual, report, name=name):
            actions_ok(report, 1)
            fresh = references.get(name + "_start")
            require(fresh is not None, "fresh start-position reference failed")
            prefix = len(actual) - len(fresh)
            require(0 < prefix < 96000, "seek did not produce the complete post-seek suffix")
            before = references["mono_full"] if name == "mono" else scene_full
            prefix_error = max(abs(x-y) for a,b in zip(actual[:prefix],before[:prefix]) for x,y in zip(a,b))
            require(prefix_error < 1e-6, "captured pre-seek audio differs from the warm processing reference")
            suffix = actual[prefix:]
            error = max(abs(x-y) for a,b in zip(suffix,fresh) for x,y in zip(a,b))
            require(error == 0, "seek history differs from fresh playback at the same native start position")
            return {"post_seek_frames": len(fresh), "captured_prefix_frames": prefix,
                    "max_error": error, "prefix_max_error": prefix_error, "decoder_preroll": "same native start-position baseline"}

        case("boundary_seek_" + name, graph, frames, 48000, assess_seek,
             actions=((.25, ["seek", "2", "absolute+exact"]),), expect_full_input=False,
             actions_after_output=True)

    silence = [(0,0)] * 9617
    original, _ = scene_oracle([(l/32768,r/32768) for l,r in frames], "bathroom", 100)
    for reinit in (False, True):
        def assess_reload(actual, report, reinit=reinit):
            actions_ok(report, 2)
            require(report.get("end_files") == [{"reason": 2, "error": 0}, {"reason": 0, "error": 0}],
                    "stop and follow-up EOF were not both observed")
            require(report.get("initialized_handles") == (2 if reinit else 1),
                    "native handle lifecycle did not match the requested boundary")
            prefix = len(actual) - len(silence)
            require(0 < prefix < len(frames), "follow-up PCM duration is incomplete")
            require(all(pair == (0,0) for pair in actual[prefix:]), "previous audio history leaked into silence")
            error = max((abs(x-y) for a,b in zip(actual[:prefix],original[:prefix]) for x,y in zip(a,b)), default=0)
            require(error < 1e-6, "captured pre-stop samples differ from the scene recurrence")
            return {"complete_followup_frames": len(silence), "captured_prefix_frames": prefix,
                    "followup_peak": 0, "prefix_max_error": error, "native_handles": report["initialized_handles"]}

        command = ["reinit", "$followup"] if reinit else ["loadfile", "$followup", "replace"]
        case("boundary_" + ("destroy_reinit" if reinit else "stop_reload"), scene_graph("bathroom", 100),
             frames, 48000, assess_reload,
             actions=((.25, ["stop"]), (.5, command)), followup_frames=silence,
             expect_full_input=False, actions_after_output=True)
