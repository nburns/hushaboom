import Foundation

public struct TreesParameters: Equatable, Sendable {
    /// 0 = occasional stirring with silent lulls ... 1 = constant movement.
    public var breeze: Float
    /// 0 = sparse individual-leaf flutter ... 1 = full canopy wash.
    public var density: Float
    /// 0 = fine needles and small leaves (bright shimmer) ... 1 = big broad
    /// leaves (darker, slower flaps).
    public var leafSize: Float

    public init(breeze: Float = 0.5, density: Float = 0.5, leafSize: Float = 0.5) {
        self.breeze = breeze
        self.density = density
        self.leafSize = leafSize
    }
}

/// Foliage modeled the way procedural audio practice does it (Farnell,
/// "Designing Sound"): a canopy is thousands of discrete leaf collisions, so
/// the sound is a granular stream whose arrival rate rides the wind. Leaves
/// stay silent below a wind-speed threshold and the rustle rises steeply
/// above it, so lulls are genuinely quiet and gusts thicken the texture.
///
/// Leaves are not all the same size, so their collisions are not all the
/// same pitch. The rustle runs through a bank of resonators spread across
/// several octaves rather than one: a single resonator collects a dense
/// stream into a narrow band around its own tuning, which lands in the
/// 2-4 kHz region the ear is most sensitive to and reads as sizzle rather
/// than leaves. Lane levels tilt down with frequency for the same reason.
///
/// `density` crossfades the bank's two drives - discrete bursts for leaves
/// you can still count, continuous noise for a canopy you cannot - and a
/// bodied air layer underneath carries the wind itself.
public struct TreesNoiseGenerator: NoiseGenerator {
    private static let windThreshold: Float = 0.12
    // Two poles, not one: the bank sheds only 6 dB/octave above its top
    // lane, and that tail is audible as sizzle over the leaves
    private static let toneCutoff: Float = 5_000

    public var parameters: TreesParameters

    private var airNoise: WhiteNoiseGenerator
    private var burstNoise: WhiteNoiseGenerator
    private var rng: SplitMix64
    private var gust: Wander
    private var airBody = OnePoleLowpass()
    private var airTone = OnePoleLowpass()
    private var burstTone = OnePoleLowpass()
    private var driveFilter = OnePoleLowpass()
    private var tone1 = OnePoleLowpass()
    private var tone2 = OnePoleLowpass()
    private var canopy = ResonatorBank()
    private var burstEnergy: Float = 0
    private var burstLane = 0
    private let sampleRate: Float

    // Parameter-derived values, refreshed only when parameters change so
    // the per-sample path stays free of exp/sin/pow
    private var derivedFor: TreesParameters?
    private var windBase: Float = 0
    private var windSpan: Float = 0
    private var washLaneGain = SIMD8<Float>()
    private var flutterLaneGain = SIMD8<Float>()
    private var flutterChance: Float = 0
    private var burstDecay: Float = 0
    private var airLevel: Float = 0

    public init(seed: UInt64? = nil, sampleRate: Double = 44_100, parameters: TreesParameters = TreesParameters()) {
        let base = SplitMix64.seedOrRandom(seed)
        airNoise = WhiteNoiseGenerator(seed: base &+ 0x3C99)
        burstNoise = WhiteNoiseGenerator(seed: base &+ 0x5B27)
        rng = SplitMix64(state: base &+ 0x8E15)
        gust = Wander(
            seed: base &+ 0xA741,
            sampleRate: Float(sampleRate),
            minHoldSeconds: 1,
            maxHoldSeconds: 5,
            glideSeconds: 1.5
        )
        self.parameters = parameters
        self.sampleRate = Float(sampleRate)
        let rate = Float(sampleRate)
        driveFilter.coefficient = OnePoleLowpass.coefficient(cutoff: 0.12, sampleRate: rate)
        // Air moving through a canopy is a bodied rush, not hiss: the old
        // 1.2 kHz highpass left nothing but the sizzle on top of it
        airBody.coefficient = OnePoleLowpass.coefficient(cutoff: 160, sampleRate: rate)
        airTone.coefficient = OnePoleLowpass.coefficient(cutoff: 1_600, sampleRate: rate)
        let k = OnePoleLowpass.coefficient(cutoff: Self.toneCutoff, sampleRate: rate)
        tone1.coefficient = k
        tone2.coefficient = k
    }

    private mutating func refreshDerived() {
        let breeze = unitClamp(parameters.breeze)
        let density = unitClamp(parameters.density)
        let leafSize = unitClamp(parameters.leafSize)

        // Breeze raises the floor and narrows the swing, so it reads as the
        // parameter says: stirring with real lulls at 0, steady movement at
        // 1. Scaling the whole range instead left the midpoint swinging
        // wider than either end
        windBase = 0.06 + 0.44 * breeze
        windSpan = 0.52 - 0.17 * breeze

        // Broad leaves are heavier: lower, longer, slower flaps
        let low = 700 - 380 * leafSize
        let high = 6_500 - 4_200 * leafSize
        let damping = 0.90 - 0.35 * leafSize
        let step = pow(high / low, 1 / Float(ResonatorBank.lanes - 1))
        burstDecay = exp(-1 / ((0.0025 + 0.005 * leafSize) * sampleRate))
        burstTone.coefficient = OnePoleLowpass.coefficient(cutoff: high * 1.2, sampleRate: sampleRate)

        // A resonator passes power in proportion to its tuning, so equal
        // lane drive would leave the canopy bright and thin
        var cutoff = low
        var energy: Float = 0
        var weights = SIMD8<Float>()
        for lane in 0..<ResonatorBank.lanes {
            canopy.setLane(lane, cutoff: cutoff, damping: damping, sampleRate: sampleRate)
            let weight = pow(cutoff / low, -0.58)
            weights[lane] = weight
            energy += weight * weight
                * StateVariableFilter.bandImpulseEnergy(tuning: canopy.tuning(lane), damping: damping)
            cutoff *= step
        }

        // Uniform drive in [-1, 1) has variance 1/3; `energy` converts that
        // into the bank's output variance
        let washLevel = 0.069 + 0.161 * density
        washLaneGain = weights * (washLevel / (energy / 3).squareRoot())

        // Flutter keeps a fixed size per collision rather than a fixed RMS,
        // so a sparse canopy is quiet instead of amplifying its few leaves
        // into the level a full one would have
        flutterChance = (60 + 1_400 * density) / sampleRate
        flutterLaneGain = weights * (1.27 * (1 - 0.5 * density))

        airLevel = 0.104
        derivedFor = parameters
    }

    public mutating func nextSample() -> Float {
        if derivedFor != parameters {
            refreshDerived()
        }

        // Thresholded, square-law wind response (Farnell): silence in the
        // lulls, rustle rising fast once the canopy starts moving
        let windSpeed = windBase + windSpan * gust.next()
        let excess = max(0, windSpeed - Self.windThreshold) * 1.35
        // Leaf inertia (Farnell, "Designing Sound" fig 41.13): leaves take a
        // while to build up energy and springy branches keep them shaking
        // after the gust stops, so the drive is heavily lagged
        let drive = driveFilter.process(min(1, excess * excess))

        // Amplitude tracks the square root so the layer's power, not its
        // level, follows the wind - the same way the collision rate does
        var excite = SIMD8<Float>()
        let washDrive = drive.squareRoot()
        for lane in 0..<ResonatorBank.lanes {
            excite[lane] = rng.nextUniform() * washLaneGain[lane] * washDrive
        }

        // Collisions are excited by short filtered noise bursts, not
        // impulses - an impulse's instant edge splatters energy above the
        // ring band and reads as sparkly pops
        if rng.nextUniform01() < drive * flutterChance {
            burstEnergy = min(1.2, burstEnergy + 0.3 + 0.7 * rng.nextUniform01())
            burstLane = min(Int(rng.nextUniform01() * Float(ResonatorBank.lanes)), ResonatorBank.lanes - 1)
        }
        excite[burstLane] += burstTone.process(burstNoise.nextSample() * burstEnergy)
            * flutterLaneGain[burstLane]
        burstEnergy *= burstDecay

        let rustle = canopy.processBand(excite)

        let w = airNoise.nextSample()
        let air = airTone.process(w - airBody.process(w)) * airLevel * drive

        return tone2.process(tone1.process(rustle + air))
    }
}
