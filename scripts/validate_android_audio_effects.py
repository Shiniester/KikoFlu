"""Run the existing PCM oracle on the Android libmpv via a tiny C API runner."""
import json
import argparse
import math
from pathlib import Path
import shlex
import struct
import subprocess
import sys
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tool/audio_effects"))
import native
import validate

ADB = "adb"
SERIAL = None
REMOTE = "/data/local/tmp/kikoflu-audio-gate"


def adb(*args, timeout=30):
    try:
        return subprocess.run([str(ADB), "-s", SERIAL, *map(str, args)],
                              capture_output=True, timeout=timeout, check=True)
    except subprocess.CalledProcessError as error:
        print(error.stderr.decode(errors="replace"), file=sys.stderr)
        raise


def run(directory, library, name, graph, frames, rate, updates=(), timeout=8,
        output_channels=2, update_target="volume@mono_amount", source_url=None,
        demuxer_format="wav", af_chain=None, actions=(), followup_frames=None,
        start_position=None, actions_after_output=False, reconfig_actions=()):
    actions = tuple(actions) + tuple((0, ["on-audio-reconfig", str(trigger_rate), *command])
                                     for trigger_rate, command in reconfig_actions)
    source = directory / (name + ".wav")
    graph_file = directory / "graph.txt"
    update_file = directory / "updates.txt"
    action_file = directory / "actions.bin"
    output = directory / (name + ".pcm")
    if not source_url:
        native.write_wav(source, frames, rate)
    if updates or actions:
        graph = graph.replace("[in]", "[in]" + native.PACING_FILTERS + ",", 1)
    if af_chain:
        if updates or actions:
            af_chain = af_chain.replace("format=channels=stereo,",
                                        "format=channels=stereo,@clock:lavfi=o=[threads=1]:graph=["
                                        + native.PACING_FILTERS + "],", 1)
        graph = "AF:" + af_chain
    graph_file.write_text(graph, encoding="utf-8")
    update_file.write_text("".join(f"{when} {value}\n" for when, value in updates), encoding="ascii")
    staged = {}

    def local_source(value):
        if urlparse(value).scheme in ("http", "https"):
            return value
        local = Path(value)
        if not local.is_file():
            return value
        local = local.resolve()
        if local in staged:
            return staged[local]
        destination = REMOTE + "/input" + str(len(staged))
        adb("shell", "mkdir", "-p", destination)
        remote_file = destination + "/" + local.name
        adb("push", local, remote_file)
        staged[local] = remote_file
        if local.suffix == ".m3u8":
            segments = [line.strip() for line in local.read_text(encoding="utf-8").splitlines()
                        if line.strip() and not line.startswith("#")]
            if segments != ["0.aac", "1.aac"]:
                raise ValueError("local HLS staging supports only the self-generated 0.aac/1.aac fixture")
            for segment in segments:
                adb("push", local.parent / segment, destination + "/" + segment)
        return remote_file

    remote_source = local_source(source_url) if source_url else REMOTE + "/source.wav"
    if not source_url:
        adb("push", source, remote_source)
    if followup_frames is not None:
        followup = directory / "followup.wav"
        native.write_wav(followup, followup_frames, rate)
        adb("push", followup, REMOTE + "/followup.wav")
    resolved_actions = []
    for when, arguments in actions:
        arguments = [REMOTE + "/followup.wav" if item == "$followup" else item for item in arguments]
        if arguments[0] in ("loadfile", "reinit"):
            arguments[1] = local_source(arguments[1])
        resolved_actions.append((when, arguments))
    with action_file.open("wb") as stream:
        stream.write(f"{len(actions)}\n".encode("ascii"))
        for when, arguments in resolved_actions:
            stream.write(f"{when} {len(arguments)}\n".encode("ascii"))
            for argument in arguments:
                data = argument.encode("utf-8")
                stream.write(f"{len(data)}\n".encode("ascii") + data + b"\n")
    adb("push", graph_file, update_file, action_file, REMOTE + "/")
    adb("shell", "rm", "-f", REMOTE + "/output.pcm")
    command = [REMOTE + "/runner", REMOTE + "/libmpv.so", remote_source,
               REMOTE + "/output.pcm", REMOTE + "/graph.txt", str(rate),
               str(output_channels), str(timeout), REMOTE + "/updates.txt", update_target, demuxer_format,
               REMOTE + "/actions.bin", "" if start_position is None else str(start_position),
               "1" if actions_after_output else "0"]
    url = urlparse(source_url or "")
    port = url.port if url.hostname in ("localhost", "127.0.0.1") else None
    if port:
        adb("reverse", f"tcp:{port}", f"tcp:{port}")
    try:
        process = subprocess.run([str(ADB), "-s", SERIAL, "shell", shlex.join(command)],
                                 capture_output=True, timeout=timeout + 10)
    except subprocess.TimeoutExpired:
        return {"name": name, "process": {"parent_timeout": True}}, []
    finally:
        if port:
            adb("reverse", "--remove", f"tcp:{port}")
    report = {"name": name, "api": [], "events": [], "logs": [], "updates": [],
              "actions": [], "end_files": [], "initialized_handles": 0,
              "action_anchor_pcm_bytes": 0, "audio_reconfigs": [],
              "versions": {}, "output_channels": output_channels,
              "process": {"return_code": process.returncode,
                          "stderr": process.stderr.decode(errors="replace")}}
    records = process.stdout.decode(errors="replace").splitlines()
    active_update_target = update_target
    for line in records:
        item = json.loads(line)
        kind, *values = item
        if kind == "api": report["api"].append(values)
        elif kind == "event":
            report["events"].append(values)
            index = values[2] - 100
            if values[0] == native.probe.COMMAND_REPLY and 0 <= index < len(report["updates"]):
                report["updates"][index]["attempts"][-1]["reply_error"] = values[1]
        elif kind == "log":
            report["logs"].append(dict(zip(("prefix", "level", "text"), values)))
        elif kind == "end":
            report["end_file"] = dict(zip(("reason", "error"), values))
            report["end_files"].append(report["end_file"])
        elif kind == "timeout": report["timed_out"] = values[0]
        elif kind == "version": report["versions"][values[0]] = values[1]
        elif kind == "ao_closed": report["ao_closed"] = values[0]
        elif kind == "usage":
            report["cpu_seconds"] = values[0]
            report["wall_seconds"] = values[1]
            report["timing"] = {"process_cpu_seconds": values[0], "wall_seconds": values[1]}
        elif kind == "update":
            report["updates"].append({"value": values[0], "enqueue_code": values[1],
                "attempts": [{"target": active_update_target, "enqueue_code": values[1]}]})
        elif kind == "retry":
            active_update_target = values[1]
            report["updates"][values[0]]["fallback"] = {"target": values[1], "enqueue_code": values[2]}
            report["updates"][values[0]]["attempts"].append({"target": values[1], "enqueue_code": values[2]})
        elif kind == "initialized": report["initialized_handles"] = values[0]
        elif kind == "audio_reconfig":
            report["audio_reconfigs"].append(dict(zip(("sample_rate", "pcm_bytes"), values)))
        elif kind == "action_anchor": report["action_anchor_pcm_bytes"] = values[0]
        elif kind == "action":
            arguments = resolved_actions[values[0]][1]
            trigger_rate = int(arguments[1]) if arguments[0] == "on-audio-reconfig" else None
            if trigger_rate is not None:
                arguments = arguments[2:]
            target = arguments[4] if arguments[0] == "af-command" and len(arguments) >= 5 else None
            record = {"command": arguments, "enqueue_code": values[1],
                      "attempts": [{"target": target, "enqueue_code": values[1]}]}
            if trigger_rate is not None:
                record["on_audio_reconfig"] = trigger_rate
            report["actions"].append(record)
        elif kind == "action_reply":
            report["actions"][values[0]].update(reply_error=values[1], pause_after_reply=values[2])
            report["actions"][values[0]]["attempts"][-1]["reply_error"] = values[1]
        elif kind == "action_retry":
            report["actions"][values[0]]["attempts"].append({"target": values[1], "enqueue_code": values[2]})
        else: raise ValueError("unknown runner record: " + kind)
    pulled = subprocess.run([str(ADB), "-s", SERIAL, "pull", REMOTE + "/output.pcm", str(output)], capture_output=True)
    report["capture"] = {"return_code": pulled.returncode,
                         "stderr": pulled.stderr.decode(errors="replace")}
    data = output.read_bytes() if pulled.returncode == 0 else b""
    report["pcm_bytes"] = len(data)
    actual = list(struct.iter_unpack("<" + "f" * output_channels, data)) if len(data) % (4*output_channels) == 0 else []
    report["pcm_frames"] = len(actual)
    (directory / (name + ".result.json")).write_text(json.dumps(report, indent=2), encoding="utf-8")
    return report, actual


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--runner", required=True, type=Path)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--libmpv", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=8)
    parser.add_argument("--suite", choices=("baseline", "adaptive", "adaptive-hls"), default="baseline")
    parser.add_argument("--ffmpeg", type=Path)
    args = parser.parse_args()
    if not args.runner.is_file() or not args.libmpv.is_file():
        parser.error("--runner and --libmpv must point to existing files")
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be positive and finite")
    if args.suite == "adaptive-hls" and (args.ffmpeg is None or not args.ffmpeg.is_file()):
        parser.error("--suite adaptive-hls requires an existing --ffmpeg executable")
    ADB, SERIAL = args.adb, args.serial
    adb("shell", "mkdir", "-p", REMOTE)
    adb("push", args.runner, REMOTE + "/runner")
    adb("push", args.libmpv, REMOTE + "/libmpv.so")
    adb("shell", "chmod", "700", REMOTE + "/runner")
    if args.suite == "baseline":
        suite = validate
    elif args.suite == "adaptive":
        import adaptive_fs as suite
    else:
        import adaptive_fs_stream as suite
    sys.argv = [sys.argv[0], "--libmpv", str(args.libmpv), "--output", str(args.output)]
    if args.suite == "baseline":
        sys.argv += ["--timeout", str(args.timeout)]
    elif args.suite == "adaptive-hls":
        sys.argv += ["--ffmpeg", str(args.ffmpeg)]
    suite.run = run
    try:
        result = suite.main()
    except SystemExit as completion:
        result = completion.code
    output_path = args.output
    report = json.loads(output_path.read_text(encoding="utf-8"))
    report["host_platform"] = report.pop("platform", sys.platform)
    report["platform"] = "Android"
    report["device"] = {key: adb("shell", "getprop", prop).stdout.decode().strip()
                        for key, prop in (("model", "ro.product.model"), ("abi", "ro.product.cpu.abi"),
                                          ("api", "ro.build.version.sdk"), ("release", "ro.build.version.release"))}
    report["native_runner"] = "libmpv C API; PCM AO; lavfi threads=1"
    report["suite"] = args.suite
    report["native_runner_path"] = str(args.runner.resolve())
    report.setdefault("unverified", []).append("Flutter app/device playback lifecycle")
    output_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    raise SystemExit(result)
