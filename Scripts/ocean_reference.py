#!/usr/bin/env python3
"""Derive the ocean match targets from a reference capture.

Only the measurements are committed (Scripts/reference/ocean-apple.json), never
the audio. Re-run this if the reference capture is ever replaced:

    python3 Scripts/ocean_reference.py capture.m4a Scripts/reference/ocean-apple.json
"""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import ocean_metrics


def to_wav(source: Path) -> Path:
    if source.suffix.lower() == ".wav":
        return source
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise SystemExit(f"{source} needs decoding but ffmpeg is not installed")
    target = Path(tempfile.mkdtemp()) / "reference.wav"
    subprocess.run(
        [ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
         "-i", str(source), "-vn", "-ac", "2", "-c:a", "pcm_s16le", str(target)],
        check=True,
    )
    return target


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        raise SystemExit(f"usage: {Path(argv[0]).name} <capture> <output.json>")
    source, destination = Path(argv[1]), Path(argv[2])
    if not source.exists():
        raise SystemExit(f"no such capture: {source}")

    rate, samples = ocean_metrics.load_mono(to_wav(source))
    reference = {
        "source": "iOS Settings > Accessibility > Background Sounds > Ocean",
        "note": "Derived measurements only. The capture itself is not redistributed.",
        "sample_rate": rate,
        **ocean_metrics.measure(rate, samples),
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(reference, indent=2) + "\n")
    print(f"wrote {destination} from {reference['duration_s']}s of {source.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
