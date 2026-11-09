"""Fixed signals for local HTTP and standards-based AAC/MPEG-TS HLS checks."""

import math
from pathlib import Path
import io
import json
import threading
import wave
import struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from graphs import scene_graph, scene_oracle

HLS_ROOT = Path(__file__).resolve().parent / "fixtures/hls"


def network_frames():
    frames = []
    for n in range(48000):
        if 7200 <= n < 7208:
            left, right = .75, -.5
        elif n < 38400:
            left = .18 * math.sin(2 * math.pi * 440 * n / 48000)
            right = .12 * math.sin(2 * math.pi * 880 * n / 48000 + .3)
        else:
            left = right = 0
        frames.append((round(left * 32767), round(right * 32767)))
    return frames


def add_transport_cases(case, require):
    frames = network_frames()
    audio = io.BytesIO()
    with wave.open(audio, "wb") as output:
        output.setnchannels(2)
        output.setsampwidth(2)
        output.setframerate(48000)
        output.writeframes(b"".join(struct.pack("<hh", *pair) for pair in frames))
    files = {"/input.wav": audio.getvalue()}
    files.update({"/hls/" + path.name: path.read_bytes() for path in HLS_ROOT.iterdir()
                  if path.suffix in (".ts", ".m3u8")})
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            data = files.get(self.path)
            if data is None:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Content-Type", "application/vnd.apple.mpegurl" if self.path.endswith(".m3u8")
                             else "video/mp2t" if self.path.endswith(".ts") else "audio/wav")
            self.end_headers()
            try:
                self.wfile.write(data)
            except BrokenPipeError:
                pass  # A decoder may close its format-probe request early.

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        origin = f"http://127.0.0.1:{server.server_port}"
        decoded = {}
        manifest = json.loads((HLS_ROOT / "fixture.json").read_text(encoding="utf-8"))
        for transport, path, frame_count, demuxer in (
            ("http", "/input.wav", len(frames), "wav"),
            ("hls", "/hls/index.m3u8", manifest["decoded_frames"], ""),
        ):
            # The AAC packet count includes encoder priming/padding; compare DSP to
            # the same native decoded baseline, not to the pre-encoding WAV.
            fixture = frames if transport == "http" else [(0,0)] * frame_count
            before = len(requests)

            def assess_bypass(actual, _, transport=transport, before=before):
                require(len(requests) > before, "native player did not request HTTP media")
                if transport == "hls":
                    require(any(path.endswith(".ts") for path in requests[before:]),
                            "HLS segments were not requested")
                require(max(abs(v) for pair in actual for v in pair) > .01, "network fixture is silent")
                decoded[transport] = actual
                return {"frames": len(actual), "requests": requests[before:].copy()}

            case("transport_" + transport + "_bypass", "[in]anull[out]", fixture, 48000, assess_bypass,
                 source_url=origin + path, demuxer_format=demuxer)
            before = len(requests)

            def assess_scene(actual, _, transport=transport, before=before):
                require(transport in decoded, "network decoding baseline failed")
                expected, _ = scene_oracle(decoded[transport], "bathroom", 100)
                error = max(abs(x-y) for a,b in zip(actual,expected) for x,y in zip(a,b))
                require(error < 1e-6, "network scene differs from native-baseline recurrence")
                require(len(requests) > before, "native effect playback did not request HTTP media")
                return {"max_error": error, "requests": requests[before:].copy()}

            case("transport_" + transport + "_scene", scene_graph("bathroom", 100), fixture, 48000, assess_scene,
                 source_url=origin + path, demuxer_format=demuxer)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
