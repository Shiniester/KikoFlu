"""Run libmpv in a disposable process; reuse the repository C API bindings."""

import ctypes
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import time
import wave

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("probe", ROOT / "scripts/probe_audio_effects.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

# Test clock only; production templates contain no pacing filter.
PACING_FILTERS = "asetnsamples=n=128:p=0,arealtime"


def write_wav(path, frames, rate):
    with wave.open(str(path), "wb") as output:
        channels = len(frames[0])
        output.setnchannels(channels)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(b"".join(struct.pack("<" + "h" * channels, *pair) for pair in frames))


def child(config_path):
    config_path = Path(config_path)
    config = json.loads(config_path.read_text(encoding="utf-8"))
    graph = config["graph"]
    actions = config.get("actions", [])
    observe_reconfigs = any(command[0] == "on-audio-reconfig" for _, command in actions)
    pace_input = config.get("pace_input", False) or config["updates"] or actions
    if pace_input:
        # Pace 128-sample frames, rather than whole decoder packets. Otherwise a
        # recursive graph can consume its control branch before queued commands
        # run, even while the outer decoder-packet pacer is still sleeping.
        graph = graph.replace("[in]", "[in]" + PACING_FILTERS + ",", 1)
    lib, dll_directory = probe.load_library(Path(config["library"]))
    probe.bind_api(lib)
    handle = lib.mpv_create()
    if not handle:
        raise RuntimeError("mpv_create returned NULL")
    report = {"api": [], "events": [], "logs": [], "updates": [],
              "actions": [], "end_files": [], "initialized_handles": 0}
    if observe_reconfigs:
        report["audio_reconfigs"] = []
    report_path = config_path.with_suffix(".result.json")

    def save():
        report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    chain = config.get("af_chain")
    if chain and pace_input:
        chain = chain.replace("format=channels=stereo,",
                              "format=channels=stereo,@clock:lavfi=o=[threads=1]:graph="
                              "[" + PACING_FILTERS + "],", 1)
    options = [
        ("config", "no"), ("load-scripts", "no"), ("terminal", "no"),
        ("vo", "null"), ("ao", "pcm"), ("ao-pcm-waveheader", "no"),
        ("ao-pcm-file", config["output"]), ("audio-format", "float"),
        ("audio-samplerate", str(config["rate"])),
        ("audio-channels", {2: "stereo", 3: "3.0", 5: "5.0"}[config["output_channels"]]),
        # Preserve mpv's native input-format remix before lavfi converts to double.
        ("af", chain if chain is not None else "format=channels=stereo,@effects:lavfi=o=[threads=1]:graph=%" + str(len(graph.encode("utf-8"))) + "%" + graph),
    ]
    if config["demuxer_format"]:
        # Repetitive synthetic WAV can otherwise be misdetected as MPEG-TS.
        options.append(("demuxer-lavf-format", config["demuxer_format"]))
    if config.get("start_position") is not None:
        options.append(("start", str(config["start_position"])))
    if actions:
        options.append(("ao-pcm-append", "yes"))

    def initialize(target_handle):
        for key, value in options:
            code = lib.mpv_set_option_string(target_handle, key.encode(), value.encode("utf-8"))
            report["api"].append([key, code])
            save()
            if code < 0:
                os._exit(3)
        lib.mpv_request_log_messages(target_handle, b"warn")
        code = lib.mpv_initialize(target_handle)
        report["api"].append(["initialize", code])
        save()
        if code < 0:
            os._exit(3)
        report["initialized_handles"] += 1

    wall_start, cpu_start = time.monotonic(), time.process_time()
    initialize(handle)
    args = (ctypes.c_char_p * 4)(
        b"loadfile", config["source"].encode("utf-8"), b"replace", None
    )
    lib.mpv_command_async(handle, 1, args)
    deadline = time.monotonic() + config["timeout"]
    loaded_at = ended_at = first_loaded_at = first_output_at = None
    output_path = Path(config["output"])
    actions_sent = 0
    sent = 0
    active_target = config["update_target"]
    retried = set()

    def send_update(index, target):
        value = config["updates"][index][1]
        args = (ctypes.c_char_p * 6)(
            b"af-command", b"effects", b"volume", str(value).encode(),
            target.encode(), None,
        )
        code = lib.mpv_command_async(handle, 100 + index, args)
        if index == len(report["updates"]):
            report["updates"].append({"value": value, "enqueue_code": code, "attempts": []})
        report["updates"][index]["attempts"].append({"target": target, "enqueue_code": code})

    while time.monotonic() < deadline:
        event = lib.mpv_wait_event(handle, 0.05).contents
        audio_rate = None
        if loaded_at is not None and sent < len(config["updates"]):
            when, value = config["updates"][sent]
            if time.monotonic() - loaded_at >= when:
                send_update(sent, active_target)
                sent += 1
        if event.event_id == probe.LOG_MESSAGE:
            message = ctypes.cast(event.data, ctypes.POINTER(probe.MpvLogMessage)).contents
            report["logs"].append({
                "prefix": message.prefix.decode(errors="replace"),
                "level": message.level.decode(errors="replace"),
                "text": message.text.decode(errors="replace").rstrip(),
            })
        elif event.event_id:
            report["events"].append([event.event_id, event.error, event.reply_userdata])
            if observe_reconfigs and event.event_id == 18:  # MPV_EVENT_AUDIO_RECONFIG
                raw = probe.property_text(lib, handle, "audio-params")
                state = json.loads(raw) if raw else {}
                audio_rate = state.get("samplerate", 0)
                report["audio_reconfigs"].append({"sample_rate": audio_rate,
                    "pcm_bytes": output_path.stat().st_size if output_path.exists() else 0})
            if event.event_id == probe.COMMAND_REPLY and 100 <= event.reply_userdata < 100 + sent:
                index = event.reply_userdata - 100
                report["updates"][index]["attempts"][-1]["reply_error"] = event.error
                if event.error == -12 and index not in retried and "@" in active_target:
                    # FFmpeg 6 names this instance "name"; newer builds use "volume@name".
                    retried.add(index)
                    active_target = active_target.split("@", 1)[1]
                    send_update(index, active_target)
            if event.event_id == probe.COMMAND_REPLY and 1000 <= event.reply_userdata < 1000 + actions_sent:
                record = report["actions"][event.reply_userdata - 1000]
                command = record["command"]
                if command[0] == "af-command":
                    record["attempts"][-1]["reply_error"] = event.error
                    if event.error == -12 and len(record["attempts"]) == 1 and "@" in command[-1]:
                        retry = command[:-1] + [command[-1].split("@", 1)[1]]
                        args = (ctypes.c_char_p * (len(retry) + 1))(
                            *(value.encode("utf-8") for value in retry), None)
                        code = lib.mpv_command_async(handle, event.reply_userdata, args)
                        record["attempts"].append({"target": retry[-1], "enqueue_code": code})
                        record["reply_error"] = None
                    else:
                        record["reply_error"] = event.error
                else:
                    record["reply_error"] = event.error
                record["pause_after_reply"] = probe.property_text(lib, handle, "pause")
            if event.event_id == probe.FILE_LOADED:
                loaded_at = time.monotonic()
                if first_loaded_at is None:
                    first_loaded_at = loaded_at
                ended_at = None
            if event.event_id == probe.END_FILE:
                end = ctypes.cast(event.data, ctypes.POINTER(probe.MpvEndFile)).contents
                report["end_file"] = {"reason": end.reason, "error": end.error}
                report["end_files"].append(report["end_file"].copy())
                ended_at = time.monotonic()
        if config.get("actions_after_output") and first_output_at is None and output_path.exists():
            size = output_path.stat().st_size
            if size > 0:
                first_output_at = time.monotonic()
                report["action_anchor_pcm_bytes"] = size
        action_anchor = first_output_at if config.get("actions_after_output") else first_loaded_at
        if action_anchor is not None and actions_sent < len(actions):
            when, command = actions[actions_sent]
            trigger_rate = int(command[1]) if command[0] == "on-audio-reconfig" else None
            due = audio_rate == trigger_rate if trigger_rate is not None else time.monotonic() - action_anchor >= when
            if due:
                if trigger_rate is not None:
                    command = command[2:]
                command = [config["followup"] if value == "$followup" else value for value in command]
                if command[0] == "reinit":
                    lib.mpv_terminate_destroy(handle)
                    handle = lib.mpv_create()
                    initialize(handle)
                    native_command = ["loadfile", command[1], "replace"]
                else:
                    native_command = command
                args = (ctypes.c_char_p * (len(native_command) + 1))(
                    *(value.encode("utf-8") for value in native_command), None)
                code = lib.mpv_command_async(handle, 1000 + actions_sent, args)
                record = {"command": command, "enqueue_code": code}
                if trigger_rate is not None:
                    record["on_audio_reconfig"] = trigger_rate
                if command[0] == "af-command":
                    record["attempts"] = [{"target": command[-1], "enqueue_code": code}]
                report["actions"].append(record)
                if native_command[0] == "loadfile":
                    ended_at = None
                actions_sent += 1
        save()
        # Drain queued filter errors even when END_FILE already arrived.
        if ended_at is not None and actions_sent == len(actions) and time.monotonic() - ended_at > 0.2:
            break
    completed = ended_at is not None and actions_sent == len(actions)
    report["timed_out"] = not completed
    report["versions"] = {
        name: probe.property_text(lib, handle, name)
        for name in ("mpv-version", "ffmpeg-version")
    }
    save()
    if not completed:
        os._exit(4)
    lib.mpv_terminate_destroy(handle)
    report["ao_closed"] = True
    report["timing"] = {"wall_seconds": time.monotonic() - wall_start,
                        "process_cpu_seconds": time.process_time() - cpu_start}
    save()
    if dll_directory:
        dll_directory.close()


def run(directory, library, name, graph, frames, rate, updates=(), timeout=8,
        output_channels=2, update_target="volume@mono_amount", source_url=None,
        demuxer_format="wav", af_chain=None, actions=(), followup_frames=None,
        start_position=None, actions_after_output=False, reconfig_actions=(),
        pace_input=False):
    actions = tuple(actions) + tuple((0, ["on-audio-reconfig", str(trigger_rate), *command])
                                     for trigger_rate, command in reconfig_actions)
    source = directory / (name + ".wav")
    output = directory / (name + ".pcm")
    config = directory / (name + ".json")
    output.unlink(missing_ok=True)
    followup = directory / (name + "-followup.wav")
    if followup_frames is not None:
        write_wav(followup, followup_frames, rate)
    if source_url is None:
        write_wav(source, frames, rate)
    config.write_text(json.dumps({
        "source": source_url or str(source), "output": str(output), "library": str(library),
        "graph": graph, "rate": rate, "updates": updates, "timeout": timeout,
        "output_channels": output_channels, "update_target": update_target,
        "demuxer_format": demuxer_format,
        "af_chain": af_chain, "actions": actions,
        "followup": str(followup) if followup_frames is not None else None,
        "start_position": start_position, "actions_after_output": actions_after_output,
        "pace_input": pace_input,
    }), encoding="utf-8")
    try:
        process = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), str(config)],
            capture_output=True, timeout=timeout + 4,
        )
        status = {"return_code": process.returncode,
                  "stderr": process.stderr.decode(errors="replace")}
    except subprocess.TimeoutExpired:
        status = {"parent_timeout": True}
    result_path = config.with_suffix(".result.json")
    report = json.loads(result_path.read_text(encoding="utf-8")) if result_path.exists() else {}
    report.update({"name": name, "process": status, "output_channels": output_channels})
    data = output.read_bytes() if output.exists() else b""
    actual = list(struct.iter_unpack("<" + "f" * output_channels, data)) if len(data) % (4 * output_channels) == 0 else []
    return report, actual


if __name__ == "__main__":
    child(sys.argv[1])
