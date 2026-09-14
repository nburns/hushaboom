#!/usr/bin/env python3
"""Generate the layered app-icon artwork in Design/icon/.

The curve is seeded pseudo-random, so this script - not the SVGs - is the
source of truth. Change a parameter below and rerun; the output is
deterministic for a given SEED.

    python3 Design/generate-icon.py
"""

import math
import os
import random

SEED = 3
HARMONICS = 14          # how many Fourier components; more = finer detail
SLOPE = 1.0             # spectral slope: 0 white, 1 pink, 2 brown
AMPLITUDE = 230.0       # peak excursion from the baseline, in px
BAND = 290.0            # total height of the nested stack at its widest, in px

CANVAS = 1024.0
SAMPLES = 1600
MIN_HALF_HEIGHT = 9.0

# Folders become groups in Icon Composer and the files inside become that
# group's layers, so this table is the group structure. Four groups is the
# documented maximum; the numeric prefixes fix the back-to-front z-order.
# Sunset ramp, outermost to innermost. Monotonic in relative luminance
# (1.00, 0.53, 0.29, 0.14, 0.06, 0.02, 0.00) so the banding survives the tinted
# appearance, where colour is discarded and only luminance separates the bands.
BANDS = [
    ("1-outer", "1-white", "#FFFFFF"),
    ("1-outer", "2-gold", "#F9B25C"),
    ("2-mid", "3-orange", "#EE6B3B"),
    ("2-mid", "4-crimson", "#C0374B"),
    ("3-inner", "5-plum", "#7C1D5C"),
    ("3-inner", "6-deep-purple", "#3E1150"),
    ("4-core", "7-night", "#16061F"),
]

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon")


def noise_curve():
    """Band-limited noise as a Fourier sum with random phases and amplitudes
    falling off as k**-SLOPE. Periodic over the canvas width, so the two
    clipped edges meet rather than jumping."""
    rng = random.Random(SEED)
    components = [
        (k, float(k) ** -SLOPE, rng.uniform(0.0, 2.0 * math.pi))
        for k in range(1, HARMONICS + 1)
    ]
    raw = []
    for i in range(SAMPLES + 1):
        x = CANVAS * i / SAMPLES
        raw.append(sum(a * math.sin(2.0 * math.pi * k * x / CANVAS + p)
                       for k, a, p in components))
    peak = max(abs(y) for y in raw)
    return [(CANVAS * i / SAMPLES, AMPLITUDE * raw[i] / peak)
            for i in range(SAMPLES + 1)]


def half_heights(count):
    step = (BAND / 2.0 - MIN_HALF_HEIGHT) / (count - 1)
    return [BAND / 2.0 - step * i for i in range(count)]


def ribbon(points, half_height, baseline):
    """Each band is the region between the curve translated up and down by a
    constant. A vertical translation cannot crowd or cusp at any curvature,
    which is what keeps the nesting clean at sharp peaks."""
    top = ["{:.2f} {:.2f}".format(x, baseline + y - half_height) for x, y in points]
    bottom = ["{:.2f} {:.2f}".format(x, baseline + y + half_height)
              for x, y in reversed(points)]
    return "M " + " L ".join(top + bottom) + " Z"


def document(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            'viewBox="0 0 1024 1024">{}</svg>'.format(body))


def main():
    points = noise_curve()
    low = min(y for _, y in points) - BAND / 2.0
    high = max(y for _, y in points) + BAND / 2.0
    baseline = CANVAS / 2.0 - (low + high) / 2.0

    combined = []
    for (group, name, color), half in zip(BANDS, half_heights(len(BANDS))):
        os.makedirs(os.path.join(OUT, group), exist_ok=True)
        path = '<path d="{}" fill="{}"/>'.format(ribbon(points, half, baseline), color)
        with open(os.path.join(OUT, group, name + ".svg"), "w") as handle:
            handle.write(document(path))
        combined.append(path)
        print("{:<8} {:<14} {}  band {:>5.1f}px".format(group, name, color, half * 2))

    with open(os.path.join(OUT, "wave-flat.svg"), "w") as handle:
        handle.write(document("".join(combined)))
    print("seed {}  harmonics {}  slope {}  baseline y {:.0f}  height {:.0f}px".format(
        SEED, HARMONICS, SLOPE, baseline, high - low))


if __name__ == "__main__":
    main()
