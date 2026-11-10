"""Measurements that define how close the ocean generator sits to a reference.

Shared by ocean_reference.py (which derives the targets from a capture) and
ocean_match.py (which scores a render against them), so both always compute a
metric the same way.
"""

import numpy as np
from scipy import signal
from scipy.io import wavfile

THIRD_OCTAVE_HZ = [
    40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000,
    1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500,
]
BANDS_HZ = [(30, 120), (120, 400), (400, 1200), (1200, 4000), (4000, 12000)]

# Band envelopes keep content up to 12 Hz so the churn rates stay visible;
# the broadband envelope is smoothed much harder because it only has to show
# the wave swell.
BAND_ENVELOPE_CUTOFF_HZ = 12.0
BAND_ENVELOPE_RATE_HZ = 50.0
BROADBAND_ENVELOPE_CUTOFF_HZ = 1.5
BROADBAND_ENVELOPE_RATE_HZ = 100.0

FIT_RANGE_HZ = (50.0, 10000.0)
CHURN_RANGE_HZ = (2.0, 10.0)
MODULATION_RANGE_HZ = (0.03, 10.0)


def load_mono(path):
    rate, data = wavfile.read(path)
    data = data.astype(np.float64)
    if np.issubdtype(data.dtype, np.integer) or np.abs(data).max() > 1.5:
        data /= 32768.0
    if data.ndim > 1:
        data = data.mean(axis=1)
    return float(rate), data


def _envelope(x, rate, cutoff, out_rate):
    b, a = signal.butter(2, cutoff / (rate / 2))
    env = signal.filtfilt(b, a, np.abs(x))
    env = env[:: max(1, int(round(rate / out_rate)))]
    return np.clip(env, 1e-12, None)


def _band(x, rate, low, high):
    high = min(high, rate / 2 * 0.98)
    sos = signal.butter(4, [low / (rate / 2), high / (rate / 2)], btype="band", output="sos")
    return signal.sosfilt(sos, x)


def _third_octave_db(freqs, power):
    out = []
    for centre in THIRD_OCTAVE_HZ:
        mask = (freqs >= centre / 2 ** (1 / 6)) & (freqs < centre * 2 ** (1 / 6))
        out.append(10 * np.log10(power[mask].mean() + 1e-20) if mask.any() else -200.0)
    out = np.array(out)
    return out - out.max()


def _modulation_fraction(env, rate, low, high):
    z = env / env.mean() - 1.0
    freqs, power = signal.welch(z, rate, nperseg=min(len(z), 1 << 11))
    total = power[(freqs > MODULATION_RANGE_HZ[0]) & (freqs < MODULATION_RANGE_HZ[1])].sum()
    if total <= 0:
        raise ValueError("envelope carries no modulation energy; input is probably silent")
    return float(power[(freqs >= low) & (freqs < high)].sum() / total)


def _crest_trough_tilt_db(x, rate, env, env_rate):
    held = np.repeat(env, int(round(rate / env_rate)))[: len(x)]
    x = x[: len(held)]
    high = x[held > np.percentile(held, 85)]
    low = x[held < np.percentile(held, 15)]

    def tilt(segment):
        freqs, power = signal.welch(segment, rate, nperseg=1 << 13)
        top = power[(freqs >= 2000) & (freqs < 8000)].sum()
        bottom = power[(freqs >= 100) & (freqs < 400)].sum()
        return 10 * np.log10((top + 1e-20) / (bottom + 1e-20))

    return float(tilt(high) - tilt(low))


def measure(rate, x):
    """Every number the match is judged on, from one mono signal."""
    if x.std() <= 0:
        raise ValueError("signal is silent")

    freqs, power = signal.welch(x, rate, nperseg=1 << 15, noverlap=1 << 14)
    third_octave = _third_octave_db(freqs, power)
    audible = (freqs > 40) & (freqs < 16000)
    centroid = float((freqs[audible] * power[audible]).sum() / power[audible].sum())

    band_envs = [
        _envelope(_band(x, rate, low, high), rate, BAND_ENVELOPE_CUTOFF_HZ, BAND_ENVELOPE_RATE_HZ)
        for low, high in BANDS_HZ
    ]
    normalised = np.array([e / e.mean() for e in band_envs])

    broadband = _envelope(x, rate, BROADBAND_ENVELOPE_CUTOFF_HZ, BROADBAND_ENVELOPE_RATE_HZ)
    broadband = broadband / broadband.mean()

    crests, _ = signal.find_peaks(
        broadband,
        distance=int(3 * BROADBAND_ENVELOPE_RATE_HZ),
        prominence=0.10,
    )
    intervals = np.diff(crests) / BROADBAND_ENVELOPE_RATE_HZ

    return {
        "duration_s": round(len(x) / rate, 2),
        "third_octave_hz": THIRD_OCTAVE_HZ,
        "third_octave_db": [round(v, 2) for v in third_octave],
        "centroid_hz": round(centroid, 1),
        "bands_hz": [list(b) for b in BANDS_HZ],
        "band_env_cv": [round(float(e.std()), 4) for e in normalised],
        "band_env_corr": [[round(float(v), 3) for v in row] for row in np.corrcoef(normalised)],
        "band_churn_fraction": [
            round(_modulation_fraction(e, BAND_ENVELOPE_RATE_HZ, *CHURN_RANGE_HZ), 4)
            for e in band_envs
        ],
        "env_p5": round(float(np.percentile(broadband, 5)), 4),
        "env_p50": round(float(np.percentile(broadband, 50)), 4),
        "env_p95": round(float(np.percentile(broadband, 95)), 4),
        "crest_trough_tilt_db": round(
            _crest_trough_tilt_db(x, rate, broadband, BROADBAND_ENVELOPE_RATE_HZ), 2
        ),
        "crest_interval_mean_s": round(float(intervals.mean()), 2) if len(intervals) else None,
        "crest_interval_cv": (
            round(float(intervals.std() / intervals.mean()), 3) if len(intervals) else None
        ),
    }


def spectrum_error_db(measured_db, reference_db):
    """RMS deviation over the band the match is fitted across."""
    centres = np.array(THIRD_OCTAVE_HZ, dtype=float)
    mask = (centres >= FIT_RANGE_HZ[0]) & (centres <= FIT_RANGE_HZ[1])
    diff = np.array(measured_db)[mask] - np.array(reference_db)[mask]
    return float(np.sqrt((diff ** 2).mean())), float(np.abs(diff).max())
