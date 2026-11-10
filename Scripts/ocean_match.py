#!/usr/bin/env python3
"""Score a rendered ocean WAV against the reference measurements.

    python3 Scripts/ocean_match.py render.wav [Scripts/reference/ocean-apple.json]

Exits non-zero if any metric is outside tolerance, so it can gate a build.
"""

import json
import sys
from pathlib import Path

import numpy as np

import ocean_metrics

# Cross-cluster pairs: the low bands against the high ones. Apple's water lets
# these drift apart; a single envelope on a broadband carrier pins them at ~1.
CROSS_CLUSTER = [(i, j) for i in (0, 1, 2) for j in (3, 4)]


def cross_cluster_corr(matrix):
    return float(np.mean([matrix[i][j] for i, j in CROSS_CLUSTER]))


def main(argv: list[str]) -> int:
    if not 2 <= len(argv) <= 3:
        raise SystemExit(f"usage: {Path(argv[0]).name} <render.wav> [reference.json]")
    render = Path(argv[1])
    reference_path = Path(argv[2]) if len(argv) == 3 else Path(__file__).parent / "reference" / "ocean-apple.json"
    if not render.exists():
        raise SystemExit(f"no such render: {render}")
    if not reference_path.exists():
        raise SystemExit(f"no such reference: {reference_path}")

    reference = json.loads(reference_path.read_text())
    rate, samples = ocean_metrics.load_mono(render)
    measured = ocean_metrics.measure(rate, samples)

    rms_error, worst_band = ocean_metrics.spectrum_error_db(
        measured["third_octave_db"], reference["third_octave_db"]
    )

    checks = [
        ("spectrum rms error", rms_error, 0.0, 1.5, "dB"),
        ("spectrum worst band", worst_band, 0.0, 4.0, "dB"),
        ("centroid", measured["centroid_hz"], reference["centroid_hz"],
         0.10 * reference["centroid_hz"], "Hz"),
        ("cross-cluster band corr", cross_cluster_corr(measured["band_env_corr"]),
         cross_cluster_corr(reference["band_env_corr"]), 0.12, ""),
        ("crest-trough tilt", measured["crest_trough_tilt_db"],
         reference["crest_trough_tilt_db"], 1.5, "dB"),
        ("envelope p5", measured["env_p5"], reference["env_p5"], 0.08, ""),
        ("envelope p50", measured["env_p50"], reference["env_p50"], 0.08, ""),
        ("envelope p95", measured["env_p95"], reference["env_p95"], 0.08, ""),
    ]
    for index, (low, high) in enumerate(ocean_metrics.BANDS_HZ):
        label = f"{low}-{high} Hz"
        checks.append((f"{label} env cv", measured["band_env_cv"][index],
                       reference["band_env_cv"][index], 0.08, ""))
        checks.append((f"{label} churn 2-10 Hz", measured["band_churn_fraction"][index],
                       reference["band_churn_fraction"][index], 0.07, ""))

    print(f"{render.name}: {measured['duration_s']}s at {rate:.0f} Hz "
          f"vs {reference_path.name} ({reference['duration_s']}s)\n")
    print(f"  {'metric':<26} {'measured':>10} {'target':>10} {'delta':>9}   ")
    failures = 0
    for name, value, target, tolerance, unit in checks:
        delta = value - target
        ok = abs(delta) <= tolerance
        failures += not ok
        print(f"  {name:<26} {value:>10.3f} {target:>10.3f} {delta:>+9.3f} {unit:<3}"
              f"{'' if ok else '  OUT (tol ' + format(tolerance, '.2f') + ')'}")

    print(f"\n  crest interval {measured['crest_interval_mean_s']}s "
          f"cv {measured['crest_interval_cv']} "
          f"(reference {reference['crest_interval_mean_s']}s cv {reference['crest_interval_cv']})")

    if failures:
        print(f"\n{failures} metric(s) out of tolerance")
        return 1
    print("\nall metrics within tolerance")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
