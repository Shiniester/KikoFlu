#!/usr/bin/env python3
"""Probe the locked libmpv audio chain with fixed PCM signals."""

import argparse
import ctypes
import json
import math
import os
import platform
import struct
import sys
import tempfile
import time
import wave
from pathlib import Path


RATE = 48_000
FRAMES = 9_600
COMMAND_REPLY = 5
FILE_LOADED = 8
END_FILE = 7
LOG_MESSAGE = 2
USERDATA = 1

CASES = (
    ("bypass", None, "identity"),
    ("equalizer_440_hz", "lavfi=[equalizer=f=440:t=q:w=1:g=6]", "filter"),
    ("lavfi_anull", "lavfi=[anull]", "filter"),
    ("lavfi_aeval", "lavfi=[aeval=exprs=val(0)|val(1)]", "filter"),
    ("lavfi_aiir", "lavfi=[aiir]", "filter"),
    ("lavfi_allpass", "lavfi=[allpass]", "filter"),
)


class MpvEvent(ctypes.Structure):
    _fields_ = [("event_id", ctypes.c_int), ("error", ctypes.c_int),
                ("reply_userdata", ctypes.c_uint64), ("data", ctypes.c_void_p)]


class MpvEndFile(ctypes.Structure):
    _fields_ = [("reason", ctypes.c_int), ("error", ctypes.c_int),
                ("playlist_entry_id", ctypes.c_int64), ("playlist_insert_id", ctypes.c_int64),
                ("playlist_insert_num_entries", ctypes.c_int)]


class MpvLogMessage(ctypes.Structure):
    _fields_ = [("prefix", ctypes.c_char_p), ("level", ctypes.c_char_p),
                ("text", ctypes.c_char_p), ("log_level", ctypes.c_int)]


def load_library(path):
    if os.name == "nt":
        dll_directory = os.add_dll_directory(str(path.parent))
    else:
        dll_directory = None
    try:
        library = ctypes.CDLL(str(path))
    except OSError:
        if dll_directory:
            dll_directory.close()
        raise
    return library, dll_directory


def bind_api(lib):
    lib.mpv_create.argtypes = []
    lib.mpv_create.restype = ctypes.c_void_p
    lib.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.mpv_set_option_string.restype = ctypes.c_int
    lib.mpv_request_log_messages.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.mpv_request_log_messages.restype = ctypes.c_int
    lib.mpv_initialize.argtypes = [ctypes.c_void_p]
    lib.mpv_initialize.restype = ctypes.c_int
    lib.mpv_command_async.argtypes = [ctypes.c_void_p, ctypes.c_uint64,
                                      ctypes.POINTER(ctypes.c_char_p)]
    lib.mpv_command_async.restype = ctypes.c_int
    lib.mpv_wait_event.argtypes = [ctypes.c_void_p, ctypes.c_double]
    lib.mpv_wait_event.restype = ctypes.POINTER(MpvEvent)
    lib.mpv_get_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.mpv_get_property_string.restype = ctypes.c_void_p
    lib.mpv_free.argtypes = [ctypes.c_void_p]
    lib.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]
    lib.mpv_terminate_destroy.restype = None
    lib.mpv_error_string.argtypes = [ctypes.c_int]
    lib.mpv_error_string.restype = ctypes.c_char_p
    lib.mpv_client_api_version.restype = ctypes.c_ulong


def error_text(lib, code):
    return lib.mpv_error_string(code).decode("utf-8", errors="replace")


def property_text(lib, handle, name):
    value = lib.mpv_get_property_string(handle, name.encode())
    if not value:
        return None
    try:
        return ctypes.string_at(value).decode("utf-8", errors="replace")
    finally:
        lib.mpv_free(value)


def make_input(path):
    frames = []
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        for n in range(FRAMES):
            left = round(6000 * math.sin(2 * math.pi * 440 * n / RATE))
            right = round(6000 * math.sin(2 * math.pi * 880 * n / RATE))
            frames.append((left, right))
        wav.writeframes(b"".join(struct.pack("<hh", *frame) for frame in frames))
    return frames


def run_case(lib, source, output, timeout, name, af):
    result = {"name": name, "filter": af, "status": "failed", "api": [],
              "events": [], "logs": [], "pcm_bytes": 0}
    handle = lib.mpv_create()
    if not handle:
        result["reason"] = "mpv_create returned NULL"
        return result, None

    try:
        options = [("config", "no"), ("terminal", "no"), ("vo", "null"),
                   ("ao", "pcm"), ("ao-pcm-waveheader", "no"),
                   ("ao-pcm-file", str(output)), ("audio-format", "s16"),
                   ("audio-samplerate", str(RATE)), ("audio-channels", "stereo")]
        if af:
            options.append(("af", af))
        for option, value in options:
            code = lib.mpv_set_option_string(handle, option.encode(), value.encode())
            result["api"].append({"operation": f"set_option:{option}", "code": code,
                                  "message": error_text(lib, code)})
            if code < 0:
                result["reason"] = f"mpv rejected option {option}"
                return result, None

        code = lib.mpv_request_log_messages(handle, b"warn")
        result["api"].append({"operation": "request_log_messages", "code": code,
                              "message": error_text(lib, code)})
        if code < 0:
            result["reason"] = "mpv rejected log subscription"
            return result, None

        code = lib.mpv_initialize(handle)
        result["api"].append({"operation": "initialize", "code": code,
                              "message": error_text(lib, code)})
        if code < 0:
            result["reason"] = "mpv_initialize failed"
            return result, None

        args = (ctypes.c_char_p * 4)(b"loadfile", str(source).encode("utf-8"), b"replace", None)
        code = lib.mpv_command_async(handle, USERDATA, args)
        result["api"].append({"operation": "loadfile_async", "code": code,
                              "message": error_text(lib, code)})
        if code < 0:
            result["reason"] = "mpv_command_async(loadfile) failed"
            return result, None

        deadline = time.monotonic() + timeout
        reply_received = ended = False
        while time.monotonic() < deadline and not (reply_received and ended):
            event = lib.mpv_wait_event(handle, min(0.25, max(0, deadline - time.monotonic()))).contents
            if event.event_id == LOG_MESSAGE:
                message = ctypes.cast(event.data, ctypes.POINTER(MpvLogMessage)).contents
                result["logs"].append({
                    "prefix": (message.prefix or b"").decode("utf-8", errors="replace"),
                    "level": (message.level or b"").decode("utf-8", errors="replace"),
                    "text": (message.text or b"").decode("utf-8", errors="replace").rstrip(),
                })
            elif event.event_id == COMMAND_REPLY and event.reply_userdata == USERDATA:
                reply_received = True
                result["events"].append({"event": "command_reply", "error": event.error,
                                         "message": error_text(lib, event.error)})
                if event.error < 0:
                    result["reason"] = "loadfile command reply failed"
            elif event.event_id == FILE_LOADED:
                result["events"].append({"event": "file_loaded", "error": event.error,
                                         "message": error_text(lib, event.error)})
            elif event.event_id == END_FILE:
                ended = True
                end = ctypes.cast(event.data, ctypes.POINTER(MpvEndFile)).contents
                result["end_file"] = {"reason": end.reason, "error": end.error,
                                      "message": error_text(lib, end.error)}
                result["events"].append({"event": "end_file", "error": end.error,
                                         "message": error_text(lib, end.error),
                                         "reason": end.reason})
        result["timed_out"] = not (reply_received and ended)
        result["mpv_version"] = property_text(lib, handle, "mpv-version")
        result["ffmpeg_version"] = property_text(lib, handle, "ffmpeg-version")
    finally:
        lib.mpv_terminate_destroy(handle)

    if output.exists():
        data = output.read_bytes()
        result["pcm_bytes"] = len(data)
        result["pcm_frames"] = len(data) // 4
    else:
        data = None
    return result, data


def assess(result, data, expected, kind):
    if result.get("reason"):
        return result["reason"]
    if result.get("timed_out"):
        return "timed out waiting for command reply and END_FILE"
    if result.get("end_file", {}).get("error", 0) < 0:
        return f"END_FILE reported mpv error {result['end_file']['error']}"
    errors = [item for item in result["logs"] if item["level"] in ("error", "fatal") or
              (item["level"] == "warn" and any(word in item["text"].lower()
                                                for word in ("filter", "not present", "failed")))]
    if errors:
        return "mpv reported filter or playback errors"
    if not data or len(data) % 4:
        return "PCM output is missing or not interleaved stereo s16le"
    actual = list(struct.iter_unpack("<hh", data))
    if len(actual) != len(expected):
        return f"PCM frame count differs: expected {len(expected)}, got {len(actual)}"
    if not result.get("events") or not any(event["event"] == "file_loaded" for event in result["events"]):
        return "FILE_LOADED event was not received"
    if kind == "identity":
        passed = actual == expected
    else:
        passed = True
    if passed:
        result["status"] = "passed"
        return None
    return "PCM samples did not match the requested effect"


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--libmpv", required=True, type=Path, help="path to the existing libmpv library")
    parser.add_argument("--output", type=Path, help="also write the JSON evidence to this path")
    parser.add_argument("--timeout", type=float, default=10.0, help="seconds to wait for each file (default: 10)")
    args = parser.parse_args(argv)
    if args.timeout <= 0 or not math.isfinite(args.timeout):
        parser.error("--timeout must be a finite number greater than zero")
    return args


def main(argv=None):
    args = parse_args(argv)
    libmpv = args.libmpv.expanduser()
    if not libmpv.exists():
        print(f"error: libmpv path does not exist: {libmpv}", file=sys.stderr)
        return 2
    if not libmpv.is_file():
        print(f"error: libmpv path is not a file: {libmpv}", file=sys.stderr)
        return 2
    try:
        lib, dll_directory = load_library(libmpv.resolve())
    except OSError as exc:
        print(f"error: could not load libmpv {libmpv}: {exc}", file=sys.stderr)
        return 2

    try:
        bind_api(lib)
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as temporary:
            temp = Path(temporary)
            source = temp / "fixed-input.wav"
            expected = make_input(source)
            checks = []
            versions = {}
            for name, af, kind in CASES:
                result, data = run_case(lib, source, temp / f"{name}.pcm", args.timeout, name, af)
                failure = assess(result, data, expected, kind)
                if failure:
                    result["reason"] = failure
                if not versions:
                    versions = {key: result.get(key) for key in ("mpv_version", "ffmpeg_version")}
                checks.append(result)
            passed = all(check["status"] == "passed" for check in checks)
            api_version = lib.mpv_client_api_version()
            report = {
                "platform": platform.system(),
                "architecture": {"machine": platform.machine(), "bits": ctypes.sizeof(ctypes.c_void_p) * 8},
                "library": {"file": libmpv.name,
                            "client_api_version": {"major": api_version >> 16, "minor": api_version & 0xFFFF},
                            **versions},
                "scope": "PCM bypass and required filter-chain availability; not full effect behavior",
                "input": {"sample_rate_hz": RATE, "channels": 2, "format": "s16le",
                          "frames": FRAMES, "tones_hz": [440, 880], "peak_s16": 6000},
                "output": {"sample_rate_hz": RATE, "channels": 2, "format": "s16le raw"},
                "checks": checks,
                "probe_status": "passed" if passed else "failed",
                "gate_status": "incomplete",
                "unverified": ["Channel swap/clone and stereo mid/side output behavior", "EQ gain response",
                               "Eara scene behavior", "Schroeder mono widening with transient and tail protection",
                               "HTTP/HLS audio, runtime updates, and playback lifecycle", "Android device execution"],
            }
    finally:
        if dll_directory:
            dll_directory.close()

    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        try:
            args.output.expanduser().write_text(encoded, encoding="utf-8")
        except OSError as exc:
            print(f"error: could not write JSON evidence {args.output}: {exc}", file=sys.stderr)
            return 2
    print(encoded, end="")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
