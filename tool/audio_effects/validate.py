#!/usr/bin/env python3
"""Validate test-only lavfi prototypes against actual libmpv PCM output."""

import argparse
import json
import math
from pathlib import Path
import platform
import sys
import tempfile

from graphs import scene_graph, mono_graph, scene_oracle
from native import run
from basic import add_channel_cases, add_stereo_cases, add_equalizer_cases
from dynamic import add_dynamic_scene_cases
from composite import add_combination_case
from transport import add_transport_cases
from limiter import add_limiter_cases
from boundaries import add_boundary_cases
from modes import add_mode_case


def require(condition, message):
    if not condition:
        raise ValueError(message)


def compare(actual, expected):
    require(len(actual) == len(expected), "PCM frame count differs")
    error = max(abs(x - y) for a, b in zip(actual, expected) for x, y in zip(a, b))
    return {"frames": len(actual), "max_error": error}


def mono_frames(rate):
    result = []
    for n in range(int(rate * 0.3)):
        t = n / rate
        value = 0.75 if 0.1 <= t < 0.1002 else (
            0.17 * math.sin(2 * math.pi * 440 * t)
            + 0.11 * math.sin(2 * math.pi * 1733 * t)
            if 0.11 < t < 0.2 else 0
        )
        sample = round(value * 32767)
        result.append((sample, sample))
    return result


def normalized(frames):
    return [(l / 32768, r / 32768) for l, r in frames]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--libmpv", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=8)
    args = parser.parse_args()
    library = args.libmpv.resolve()
    if not library.is_file():
        parser.error("--libmpv must point to an existing library")
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be positive and finite")
    checks = []
    captured = {}
    args.output = args.output.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pcm-", dir=args.output.parent) as temporary:
        directory = Path(temporary)

        def case(name, graph, frames, rate, assess, updates=(), output_channels=2,
                 update_target="volume@mono_amount", source_url=None, demuxer_format="wav",
                 af_chain=None, actions=(), followup_frames=None, start_position=None,
                 expect_full_input=True, actions_after_output=False):
            transport_options = {} if source_url is None else {
                "source_url": source_url, "demuxer_format": demuxer_format,
            }
            if af_chain is not None:
                transport_options["af_chain"] = af_chain
            if actions:
                transport_options["actions"] = actions
            if actions_after_output:
                transport_options["actions_after_output"] = True
            if followup_frames is not None:
                transport_options["followup_frames"] = followup_frames
            if start_position is not None:
                transport_options["start_position"] = start_position
            report, actual = run(directory, library, name, graph, frames, rate, updates, args.timeout,
                                 output_channels, update_target, **transport_options)
            try:
                require(report["process"].get("return_code") == 0, "native child failed or timed out")
                require(report.get("end_file") == {"reason": 0, "error": 0}, "playback did not reach EOF")
                require(not report.get("timed_out"), "native processing timed out")
                require(not any(log["level"] in ("error", "fatal") for log in report.get("logs", [])),
                        "native filter failed; automatic bypass is not a pass")
                if expect_full_input:
                    require(len(actual) == len(frames), "native PCM length differs from input")
                require(all(math.isfinite(v) for pair in actual for v in pair), "non-finite PCM")
                report["metrics"] = assess(actual, report)
                report["status"] = "passed"
                captured[name] = actual
            except (ValueError, KeyError) as error:
                report["status"] = "failed"
                report["reason"] = str(error)
            checks.append(report)
            print(name + ": " + report["status"], file=sys.stderr)

        add_channel_cases(case, require)
        add_stereo_cases(case, require)
        add_equalizer_cases(case, require)

        frames = [
            (round(0.97 * math.sin(2 * math.pi * 1000 * n / 48000) * 32767),
             round(0.94 * math.sin(2 * math.pi * 1000 * n / 48000 + 0.15) * 32767))
            if n < 24000 else (0, 0) for n in range(33600)
        ]
        expected, clamps = scene_oracle(normalized(frames), "bathroom", 100)
        require(clamps > 0, "bathroom fixture must exercise feedback write clipping")

        def assess_bathroom(actual, _):
            metrics = compare(actual, expected)
            require(metrics["max_error"] < 1e-6, "bathroom differs from Eara recurrence")
            return {**metrics, "oracle_feedback_write_clips": clamps}

        for chunk in (128, 1024, 4096):
            case("bathroom_" + str(chunk), scene_graph("bathroom", 100, chunk=chunk), frames, 48000, assess_bathroom)

        for scene in ("bathroom", "through_wall", "telephone"):
            for amount in (0, 50, 100):
                expected_scene, clipped = scene_oracle(normalized(frames), scene, amount)

                def assess_scene(actual, _, expected=expected_scene, amount=amount, clipped=clipped):
                    metrics = compare(actual, expected)
                    require(metrics["max_error"] == 0 if amount == 0 else metrics["max_error"] < 1e-6,
                            "scene output differs from fixed Eara behavior")
                    return {**metrics, "oracle_feedback_write_clips": clipped}

                case(f"scene_{scene}_{amount}", scene_graph(scene, amount), frames, 48000, assess_scene)

        for rate in (44100, 48000, 96000):
            frames = mono_frames(rate)
            expected_mono = normalized(frames)
            base_graph = mono_graph(rate)
            graph_on = base_graph.replace("volume@mono_amount=0:", "volume@mono_amount=1:")
            prefix = "mono_" + str(rate)
            single_channel = [(pair[0],) for pair in frames]

            def assess_mono_bypass(actual, _, frames=single_channel):
                require(actual[0] == (0, 0), "mono silence generated output")
                require(all(l == r for l, r in actual), "mono bypass channels differ")
                peak = max(range(len(frames)), key=lambda n: abs(frames[n][0]))
                gain = actual[peak][0] / (frames[peak][0] / 32768)
                require(gain > 0, "mono bypass was silent")
                return {"mono_to_stereo_per_ear_gain": gain}

            case(prefix + "_one_channel_bypass", "[in]anull[out]", single_channel, rate, assess_mono_bypass)

            def assess_mono_neutral(actual, _, prefix=prefix):
                baseline = captured.get(prefix + "_one_channel_bypass")
                require(baseline is not None, "native mono bypass prerequisite failed")
                metrics = compare(actual, baseline)
                require(metrics["max_error"] == 0, "neutral changed native mono conversion gain")
                return metrics

            case(prefix + "_one_channel_neutral", base_graph, single_channel, rate, assess_mono_neutral)

            def assess_neutral(actual, _, expected=expected_mono):
                metrics = compare(actual, expected)
                require(metrics["max_error"] == 0, "zero strength must preserve PCM")
                return metrics

            def assess_widening(actual, _, expected=expected_mono, rate=rate):
                error = max(abs((l + r) / 2 - pair[0]) for (l, r), pair in zip(actual, expected))
                require(error < 1e-7, "linear mid/side synthesis lost the original mono")
                tail = max(abs(v) for pair in actual[int(rate * 0.23):] for v in pair)
                require(tail < 1e-5, "processed tail exceeds prototype -100 dBFS bound")
                return {"midside_max_error": error, "tail_after_30ms_peak": tail}

            case(prefix + "_neutral", base_graph, frames, rate, assess_neutral)
            case(prefix + "_protected", graph_on, frames, rate, assess_widening)
            no_protection = graph_on.replace("*(1-ld(4))*min(1,ld(1)/(ld(5)+1e-12))", "")

            def assess_transient(actual, _, rate=rate, prefix=prefix):
                protected = captured.get(prefix + "_protected")
                require(protected is not None, "protected PCM prerequisite failed")
                onset = range(int(rate * 0.1), int(rate * 0.1002))
                peak = max(abs((actual[n][0] - actual[n][1]) / 2) for n in onset)
                protected_peak = max(abs((protected[n][0] - protected[n][1]) / 2) for n in onset)
                require(peak > 0.01 and protected_peak < peak * 0.1,
                        "transient protection must attenuate this isolated onset by 90%")
                return {"unprotected_side_peak": peak, "protected_side_peak": protected_peak}

            case(prefix + "_transient", no_protection, frames, rate, assess_transient)

            def assess_blocks(actual, _, prefix=prefix):
                require(prefix + "_protected" in captured, "protected PCM prerequisite failed")
                metrics = compare(actual, captured[prefix + "_protected"])
                require(metrics["max_error"] < 1e-7, "PCM depends on input block boundaries")
                return metrics

            chunked = graph_on.replace("asplit=3[dry]", "asetnsamples=n=127:p=0,asplit=3[dry]")
            case(prefix + "_block127", chunked, frames, rate, assess_blocks)
            if rate == 48000:
                stereo = []
                original_side = []
                for n, (m, _) in enumerate(frames):
                    side = round(0.03 * math.sin(2 * math.pi * 700 * n / rate) * 32767)
                    stereo.append((m + side, m - side))
                    original_side.append(side / 32768)

                def assess_existing_side(actual, _):
                    protected = captured.get("mono_48000_protected")
                    require(protected is not None, "protected PCM prerequisite failed")
                    error = max(abs((l-r)/2-(a-b)/2-s) for (l,r),(a,b),s
                                in zip(actual, protected, original_side))
                    require(error < 1e-7, "original side signal was lost")
                    return {"original_side_max_error": error}

                case("mono_existing_side", graph_on, stereo, rate, assess_existing_side)

        frames = [(6000, 6000)] * 96000
        updates = ((0.3, 1), (0.8, 0), (1.3, 0.6))
        ramp = (
            "[in]aeval=1:c=mono,volume@mono_amount=0:precision=double,"
            "aformat=sample_fmts=dblp:channel_layouts=mono,"
            "aeval='st(0,ld(0)+clip(val(0)-ld(0),-1/(s*.02),1/(s*.02)));ld(0)|"
            "st(0,ld(0)+clip(val(0)-ld(0),-1/(s*.02),1/(s*.02)));ld(0)':c=stereo,aformat=channel_layouts=stereo[out]"
        )

        def assess_updates(actual, report):
            require(len(report["updates"]) == 3, "not all updates were sent")
            require(all([5, 0, 100 + n] in report["events"] for n in range(3)), "af-command failed")
            require(sum(e[0] == 8 for e in report["events"]) == 1, "media was loaded again")
            step = max(abs(b[0]-a[0]) for a,b in zip(actual, actual[1:]))
            require(step <= 1/960 + 1e-7, "parameter update exceeded 20 ms full-scale slew")
            require(actual[0][0] == 0 and abs(actual[-1][0] - 0.6) < 1e-7, "final target not applied")
            require(max(x[0] for x in actual) == 1, "enable target never reached")
            return {"maximum_sample_step": step, "step_bound": 1/960}

        case("runtime_updates", ramp, frames, 48000, assess_updates, updates)
        add_dynamic_scene_cases(case, require)
        add_combination_case(case, require)
        add_transport_cases(case, require)
        add_limiter_cases(case, require)
        add_boundary_cases(case, require)
        add_mode_case(case, require)

    report = {
        "platform": platform.platform(), "library": str(library),
        "scope": "Actual PCM: EQ/channel modes/stereo width, static/dynamic Eara scenes, mono prototype, runtime lane",
        "gate_status": "incomplete",
        "unverified": ["Android/device lifecycle", "Project native builds unless explicitly selected",
                       "CPU and headphone listening", "Combined-effect output headroom",
                       "App mode persistence; queue/preload/background/system controls"],
        "checks": checks,
        "status": "passed" if all(c["status"] == "passed" for c in checks) else "failed",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "gate_status": "incomplete",
                      "checks": len(checks), "output": str(args.output)}))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
