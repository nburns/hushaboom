import Foundation

public struct RainParameters: Equatable, Sendable {
    /// 0 = light drizzle ... 1 = downpour. Controls the level and how many
    /// individual impacts are audible in the wash.
    public var intensity: Float
    /// 0 = soft ground and leaves ... 1 = hard roof or window.
    public var surface: Float
    /// Foreground drip arrivals, exponential: 0 = ~1/s ... 1 = ~60/s.
    public var rate: Float
    /// 0 = fine mist ticks ... 1 = fat drops, lower-pitched and louder.
    public var dropSize: Float

    public init(intensity: Float = 0.5, surface: Float = 0.5, rate: Float = 0.5, dropSize: Float = 0.5) {
        self.intensity = intensity
        self.surface = surface
        self.rate = rate
        self.dropSize = dropSize
    }
}

/// Rain is thousands of impacts per second on a surface, and what tells the
/// ear it is rain rather than static is that the impacts are spread over
/// several octaves. So the whole sound is built from one bank of resonators
/// log-spaced across the audible impact range, driven two ways at once:
/// continuous noise for the dense wash that no ear can resolve, and sparse
/// discrete strikes for the grains it can. Sharing the bank puts the grains
/// inside the wash's own spectrum, which is where the real ones are.
///
/// Lane levels are weighted down with frequency so the bank's aggregate
/// slopes off above the low mids. Without that tilt the sound piles up
/// around 3-4 kHz, where the ear is most sensitive, and reads as harsh hiss.
///
/// On top sit sparse individual drips (`rate`, `dropSize`) with their own
/// bank, pitch-randomized so no two land on the same note, and the whole
/// mix breathes on a slow wander because steady rain never holds still.
///
/// Each layer is normalized against its own density, tuning, and damping, so
/// moving a slider changes character without changing loudness.
public struct RainNoiseGenerator: NoiseGenerator {
    // Two poles, not one: the bank only sheds 6 dB/octave above its top
    // lane, which leaves an audible 8-16 kHz hiss over the rain
    private static let toneCutoff: Float = 7_000

    public var parameters: RainParameters

    private var rng: SplitMix64
    private var tone1 = OnePoleLowpass()
    private var tone2 = OnePoleLowpass()
    private var patter = ResonatorBank()
    private var drops = ResonatorBank()
    private var breath: Wander
    private let sampleRate: Float

    // Parameter-derived values, refreshed only when parameters change so
    // the per-sample path stays free of exp/sin/pow
    private var derivedFor: RainParameters?
    private var washLaneGain = SIMD8<Float>()
    private var grainLaneGain = SIMD8<Float>()
    private var grainChance: Float = 0
    private var dropLaneGain = SIMD8<Float>()
    private var dropChance: Float = 0

    public init(seed: UInt64? = nil, sampleRate: Double = 44_100, parameters: RainParameters = RainParameters()) {
        let base = SplitMix64.seedOrRandom(seed)
        rng = SplitMix64(state: base &+ 0x6D0B)
        breath = Wander(
            seed: base &+ 0x4F1C,
            sampleRate: Float(sampleRate),
            minHoldSeconds: 4,
            maxHoldSeconds: 12,
            glideSeconds: 3.5
        )
        self.parameters = parameters
        self.sampleRate = Float(sampleRate)
        let k = OnePoleLowpass.coefficient(cutoff: Self.toneCutoff, sampleRate: Float(sampleRate))
        tone1.coefficient = k
        tone2.coefficient = k
    }

    private mutating func refreshPatter(intensity: Float, surface: Float) {
        // Hard surfaces ring brighter and tighter; soft ground damps impacts
        // into dull thuds
        let damping = 0.95 - 0.30 * surface
        let low = 180 + 260 * surface
        let high = 2_000 + 3_200 * surface
        let step = pow(high / low, 1 / Float(ResonatorBank.lanes - 1))

        // A resonator passes power in proportion to its tuning, so equal
        // lane drive would leave the bank bright and thin. The exponent puts
        // the aggregate near -3 dB/octave, close to the slope of real rain
        var cutoff = low
        var energy: Float = 0
        var loudestStrike: Float = 0
        var weights = SIMD8<Float>()
        for lane in 0..<ResonatorBank.lanes {
            patter.setLane(lane, cutoff: cutoff, damping: damping, sampleRate: sampleRate)
            let tuning = patter.tuning(lane)
            let weight = pow(cutoff / low, -0.52)
            weights[lane] = weight
            energy += weight * weight * StateVariableFilter.bandImpulseEnergy(tuning: tuning, damping: damping)
            // A strike peaks at drive * tuning, and the upper lanes win that
            // race even after the tilt
            loudestStrike = max(loudestStrike, weight * tuning)
            cutoff *= step
        }

        // Uniform drive in [-1, 1) has variance 1/3; `energy` converts that
        // into the bank's output variance
        let washLevel = 0.100 + 0.085 * intensity
        washLaneGain = weights * (washLevel / (energy / 3).squareRoot())

        // Grains are normalized by peak rather than RMS: they exist to be
        // heard as separate impacts, so each one should land at a fixed size
        // no matter how many arrive
        grainChance = (80 + 1_200 * intensity) / sampleRate
        grainLaneGain = weights * ((0.050 + 0.040 * intensity) / loudestStrike)
    }

    private mutating func refreshDrops(surface: Float, rate: Float, dropSize: Float) {
        dropChance = 1.2 * pow(50, rate) / sampleRate

        // Fat drops thud low and ring on; mist ticks high and dies fast
        let center = (500 + 850 * surface) * (1.6 - 1.15 * dropSize)
        let damping = max(0.08, 0.42 - 0.24 * dropSize)
        // Held near the center rather than spread over octaves: these should
        // read as the same kind of drop, just never the same note
        let spread: SIMD8<Float> = [0.62, 0.72, 0.84, 0.94, 1.08, 1.22, 1.40, 1.62]
        let peak = 0.11 * (0.60 + 0.80 * dropSize)
        for lane in 0..<ResonatorBank.lanes {
            drops.setLane(lane, cutoff: center * spread[lane], damping: damping, sampleRate: sampleRate)
            dropLaneGain[lane] = peak / drops.tuning(lane)
        }
    }

    private mutating func refreshDerived() {
        let surface = unitClamp(parameters.surface)
        refreshPatter(intensity: unitClamp(parameters.intensity), surface: surface)
        refreshDrops(surface: surface, rate: unitClamp(parameters.rate), dropSize: unitClamp(parameters.dropSize))
        derivedFor = parameters
    }

    /// A Poisson-timed impact: zero on most samples, otherwise a signed
    /// amplitude in [low, 1] scattered onto one lane of a bank.
    private mutating func strike(chance: Float, low: Float, gain: SIMD8<Float>) -> SIMD8<Float> {
        var drive = SIMD8<Float>()
        guard rng.nextUniform01() < chance else { return drive }
        let amplitude = (low + (1 - low) * rng.nextUniform01()) * (rng.nextUniform01() < 0.5 ? -1 : 1)
        let lane = min(Int(rng.nextUniform01() * Float(ResonatorBank.lanes)), ResonatorBank.lanes - 1)
        drive[lane] = amplitude * gain[lane]
        return drive
    }

    public mutating func nextSample() -> Float {
        if derivedFor != parameters {
            refreshDerived()
        }

        // Independent noise per lane. One shared source would make the lanes
        // sum coherently and comb where neighbours overlap
        var drive = SIMD8<Float>()
        for lane in 0..<ResonatorBank.lanes {
            drive[lane] = rng.nextUniform() * washLaneGain[lane]
        }
        drive += strike(chance: grainChance, low: 0.35, gain: grainLaneGain)
        let wash = tone2.process(tone1.process(patter.processBand(drive)))

        let drips = drops.processBand(strike(chance: dropChance, low: 0.45, gain: dropLaneGain))

        // Real rain swells and eases; a fixed level reads as a machine
        return (wash + drips) * (0.82 + 0.20 * breath.next())
    }
}
