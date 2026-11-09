"""Regenerate the small synthetic AAC/MPEG-TS HLS fixture (FFmpeg 6.1.1)."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from native import write_wav
from transport import network_frames, HLS_ROOT

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--ffmpeg", required=True, type=Path)
args = parser.parse_args()
ffmpeg = str(args.ffmpeg.resolve())
HLS_ROOT.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="hls-", dir=HLS_ROOT.parent) as temporary:
    source = Path(temporary) / "input.wav"
    decoded = Path(temporary) / "decoded.pcm"
    write_wav(source, network_frames(), 48000)
    subprocess.run([
        ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
        "-c:a", "aac", "-b:a", "96k", "-f", "hls", "-hls_time", "0.5",
        "-hls_playlist_type", "vod", "-hls_segment_filename", "segment%02d.ts", "index.m3u8",
    ], cwd=HLS_ROOT, check=True)
    subprocess.run([
        ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(HLS_ROOT / "index.m3u8"),
        "-f", "f32le", "-acodec", "pcm_f32le", str(decoded),
    ], check=True)
    version = subprocess.check_output([ffmpeg, "-version"], text=True).splitlines()[0]
    (HLS_ROOT / "fixture.json").write_text(json.dumps({
        "generator": version, "sample_rate": 48000, "channels": 2,
        "source_frames": 48000, "decoded_frames": decoded.stat().st_size // 8,
        "signal": "network_frames() in transport.py; synthesized locally",
        "generator_source": "https://github.com/eugeneware/ffmpeg-static/releases/tag/b6.1.1",
    }, indent=2) + "\n", encoding="utf-8")
