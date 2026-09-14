import Foundation

struct OnePoleLowpass {
    var state: Float = 0
    var coefficient: Float = 0.1

    static func coefficient(cutoff: Float, sampleRate: Float) -> Float {
        1 - exp(-2 * .pi * min(cutoff, sampleRate * 0.45) / sampleRate)
    }

    // Stationary output RMS for unit-RMS white input
    static func noiseRMSRatio(coefficient k: Float) -> Float {
        (k / (2 - k)).squareRoot()
    }

    // A-weighted RMS of one-pole-lowpassed white noise relative to
    // unweighted white; rational fit to the numeric integral at 48 kHz,
    // within 0.4 dB for cutoffs 100 Hz...3 kHz
    static func aWeightedNoiseRMSRatio(cutoff c: Float) -> Float {
        c / ((c + 1_447) * (c + 3_573)).squareRoot()
    }

    mutating func process(_ x: Float) -> Float {
        state += (x - state) * coefficient
        return state
    }
}

// Chamberlin state-variable filter; stable for cutoff < sampleRate/6
struct StateVariableFilter {
    private var low: Float = 0
    private var band: Float = 0
    private var f: Float = 0.1
    private var damping: Float = 1

    static func tuning(cutoff: Float, sampleRate: Float) -> Float {
        2 * sin(.pi * min(cutoff, sampleRate / 6.5) / sampleRate)
    }

    // Sum of squares of the band output's impulse response. Exact limit is
    // f/(2*damping); the correction tracks the error that grows as the
    // cutoff approaches the stability edge. Used to hold a layer's level
    // steady as its tuning and damping move.
    static func bandImpulseEnergy(tuning f: Float, damping q: Float) -> Float {
        f * (2 + 1.2 * f * f * (0.5 + q)) / (4 * q)
    }

    mutating func set(cutoff: Float, damping: Float, sampleRate: Float) {
        f = Self.tuning(cutoff: cutoff, sampleRate: sampleRate)
        self.damping = max(0.05, damping)
    }

    mutating func processBand(_ x: Float) -> Float {
        low += f * band
        let high = x - low - damping * band
        band += f * high
        return band
    }
}

/// Aperiodic slow modulation in [0, 1]: picks a random target every few
/// seconds and glides toward it with a one-pole ramp.
struct Wander {
    private var rng: SplitMix64
    private var current: Float
    private var target: Float
    private var samplesUntilRetarget = 0
    private let glide: Float
    private let minHold: Int
    private let maxHold: Int

    init(seed: UInt64, sampleRate: Float, minHoldSeconds: Float, maxHoldSeconds: Float, glideSeconds: Float) {
        rng = SplitMix64(state: seed)
        minHold = max(1, Int(minHoldSeconds * sampleRate))
        maxHold = max(minHold + 1, Int(maxHoldSeconds * sampleRate))
        glide = 1 - exp(-1 / (glideSeconds * sampleRate))
        current = 0.5
        target = 0.5
    }

    mutating func next() -> Float {
        if samplesUntilRetarget <= 0 {
            target = rng.nextUniform01()
            samplesUntilRetarget = minHold + Int(rng.nextUniform01() * Float(maxHold - minHold))
        }
        samplesUntilRetarget -= 1
        current += (target - current) * glide
        return current
    }
}

func unitClamp(_ x: Float) -> Float {
    max(0, min(1, x))
}

/// A parallel bank of Chamberlin bandpass resonators, one per SIMD lane.
/// Impacts are scattered across lanes tuned to different centers, so a
/// dense stream of them reads as broadband texture rather than one
/// ringing pitch - a single shared resonator turns into a tone as soon as
/// impacts arrive faster than it decays.
///
/// An untuned lane holds f = 0 and stays silent, so a caller wanting fewer
/// than eight resonators just leaves the rest alone.
struct ResonatorBank {
    static let lanes = 8

    private var low = SIMD8<Float>()
    private var band = SIMD8<Float>()
    private var f = SIMD8<Float>()
    private var damping = SIMD8<Float>(repeating: 1)

    mutating func setLane(_ index: Int, cutoff: Float, damping q: Float, sampleRate: Float) {
        f[index] = StateVariableFilter.tuning(cutoff: cutoff, sampleRate: sampleRate)
        damping[index] = max(0.05, q)
    }

    func tuning(_ index: Int) -> Float {
        f[index]
    }

    mutating func processBand(_ x: SIMD8<Float>) -> Float {
        low += f * band
        let high = x - low - damping * band
        band += f * high
        return band.sum()
    }
}
