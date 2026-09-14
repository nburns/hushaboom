import Foundation

public struct WindParameters: Equatable, Sendable {
    /// 0 = steady breeze ... 1 = strong irregular gusts.
    public var gustiness: Float
    /// 0 = dark distant rumble ... 1 = bright whistling close-up.
    public var tone: Float

    public init(gustiness: Float = 0.5, tone: Float = 0.5) {
        self.gustiness = gustiness
        self.tone = tone
    }
}

/// White noise through a lowpass whose cutoff wanders with the gust
/// envelope - wind gets brighter as it gets stronger. A resonant band
/// mixed in with `tone` adds the whistle of close-up wind.
public struct WindNoiseGenerator: NoiseGenerator {
    private static let gain: Float = 0.75

    public var parameters: WindParameters

    // The lowpass sweeps with the gust, so its coefficients are refreshed
    // at control rate rather than per sample - 32 samples (~0.7 ms) is far
    // finer than the ~2 s gust glide it tracks
    private static let controlInterval = 32

    private var white: WhiteNoiseGenerator
    private var gust: Wander
    private var lowpass = OnePoleLowpass()
    private var whistle = StateVariableFilter()
    private let sampleRate: Float

    private var derivedFor: WindParameters?
    private var gustDepth: Float = 0
    private var minCutoff: Float = 0
    private var maxCutoff: Float = 0
    private var whistleDamping: Float = 0
    private var whistleGain: Float = 0
    private var controlCountdown = 0
    private var strength: Float = 0
    private var makeup: Float = 1

    public init(seed: UInt64? = nil, sampleRate: Double = 44_100, parameters: WindParameters = WindParameters()) {
        let base = SplitMix64.seedOrRandom(seed)
        white = WhiteNoiseGenerator(seed: base &+ 0x51D3)
        gust = Wander(
            seed: base &+ 0x77AB,
            sampleRate: Float(sampleRate),
            minHoldSeconds: 1.5,
            maxHoldSeconds: 6,
            glideSeconds: 2
        )
        self.parameters = parameters
        self.sampleRate = Float(sampleRate)
    }

    private mutating func refreshDerived() {
        let gustiness = unitClamp(parameters.gustiness)
        let tone = unitClamp(parameters.tone)
        gustDepth = 0.15 + 0.75 * gustiness
        // Quadratics keep tone 0.5 where it always was but raise the dark
        // floor (tone 0), which otherwise fades to a near-inaudible rumble
        minCutoff = 200 + 40 * tone + 160 * tone * tone
        maxCutoff = 1_000 + 900 * tone + 600 * tone * tone
        whistleDamping = 0.5 - 0.35 * tone
        // Resonator gain grows as damping falls; sqrt(damping) keeps the
        // whistle level steady across the tone range
        whistleGain = tone > 0.01 ? 0.8 * tone * whistleDamping.squareRoot() : 0
        derivedFor = parameters
        controlCountdown = 0
    }

    private mutating func updateControlRate(gustValue: Float) {
        strength = (1 - gustDepth) + gustDepth * gustValue
        let cutoff = minCutoff + (maxCutoff - minCutoff) * strength * strength
        let k = OnePoleLowpass.coefficient(cutoff: cutoff, sampleRate: sampleRate)
        lowpass.coefficient = k
        // Makeup keeps loudness from tracking the filter cutoff; the gust
        // envelope alone carries the level swings. Flat-RMS makeup alone
        // still reads quieter as the cutoff drops (equal-loudness), so
        // tilt toward the A-weighted level - clamped so the dark end
        // can't overrun flat-RMS headroom; 1.184 makes the tilt 1 at 1 kHz
        let flat = max(0.05, OnePoleLowpass.noiseRMSRatio(coefficient: k))
        let aRatio = max(0.001, OnePoleLowpass.aWeightedNoiseRMSRatio(cutoff: cutoff))
        let tilt = min(1.4, max(0.85, 1.184 * flat / aRatio))
        makeup = tilt / flat
        if whistleGain > 0 {
            whistle.set(cutoff: cutoff * 2.5, damping: whistleDamping, sampleRate: sampleRate)
        }
    }

    public mutating func nextSample() -> Float {
        if derivedFor != parameters {
            refreshDerived()
        }
        // Wander is timed per sample, so it always advances; only the
        // transcendental-heavy filter updates are decimated
        let gustValue = gust.next()
        if controlCountdown == 0 {
            updateControlRate(gustValue: gustValue)
            controlCountdown = Self.controlInterval
        }
        controlCountdown -= 1

        let w = white.nextSample()
        var sample = lowpass.process(w) * makeup
        if whistleGain > 0 {
            sample += whistle.processBand(w) * whistleGain
        }
        return sample * strength * Self.gain
    }
}
