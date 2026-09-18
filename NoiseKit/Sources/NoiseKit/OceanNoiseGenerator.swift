import Foundation

/// Raw synthesis controls for `OceanNoiseGenerator`. Defaults reproduce the
/// stock ocean sound; `init(wavePeriod:waveHeight:tone:waveVariation:)` maps
/// four perceptual macros onto the raw fields.
public struct OceanParameters: Equatable, Sendable {
    /// Surf level between waves, 0...1 of the envelope.
    public var bedLevel: Float
    /// How far above the bed a full-height wave swells, 0...1.
    public var waveDepth: Float
    /// Typical wave cycle length in seconds; each wave is drawn around it.
    public var waveSeconds: Float
    /// Per-wave spread as a fraction of `waveSeconds`, 0...1. At 0 every
    /// wave lasts exactly `waveSeconds`.
    public var waveSecondsVariation: Float
    /// Random per-wave height range, 0...1.
    public var minWavePeak: Float
    public var maxWavePeak: Float
    /// Random per-wave rise fraction range: lower = slow build, abrupt crash.
    public var minRiseFraction: Float
    public var maxRiseFraction: Float
    /// Carrier blend: 0 = all brown (deep rumble), 1 = all pink (close hiss).
    public var carrierMix: Float
    /// How much the carrier tilts toward bright noise as a wave crashes, 0...1.
    public var crashBrightness: Float

    public init(
        bedLevel: Float = 0.30,
        waveDepth: Float = 0.70,
        waveSeconds: Float = 10,
        waveSecondsVariation: Float = 0.375,
        minWavePeak: Float = 0.5,
        maxWavePeak: Float = 1.0,
        minRiseFraction: Float = 0.5,
        maxRiseFraction: Float = 0.7,
        carrierMix: Float = 0.35,
        crashBrightness: Float = 0.3
    ) {
        self.bedLevel = bedLevel
        self.waveDepth = waveDepth
        self.waveSeconds = waveSeconds
        self.waveSecondsVariation = waveSecondsVariation
        self.minWavePeak = minWavePeak
        self.maxWavePeak = maxWavePeak
        self.minRiseFraction = minRiseFraction
        self.maxRiseFraction = maxRiseFraction
        self.carrierMix = carrierMix
        self.crashBrightness = crashBrightness
    }

    /// Perceptual macros, each 0...1:
    /// `wavePeriod` 0 = short frequent waves ... 1 = long slow rollers,
    /// `waveHeight` 0 = gentle swells over steady surf ... 1 = big crashes,
    /// `tone` 0 = deep/distant ... 1 = bright/close,
    /// `waveVariation` 0 = every wave the same length ... 1 = wildly irregular.
    /// (0.5, 0.5, 0.5, 0.5) approximates the defaults.
    public init(wavePeriod: Float, waveHeight: Float, tone: Float, waveVariation: Float = 0.5) {
        let p = max(0, min(1, wavePeriod))
        let h = max(0, min(1, waveHeight))
        let t = max(0, min(1, tone))
        let v = max(0, min(1, waveVariation))
        self.init(
            bedLevel: 0.45 - 0.30 * h,
            waveDepth: 0.55 + 0.30 * h,
            waveSeconds: 6 + 8.5 * p,
            waveSecondsVariation: 0.75 * v,
            minWavePeak: 0.60 - 0.25 * h,
            maxWavePeak: 0.80 + 0.20 * h,
            minRiseFraction: 0.60 - 0.15 * h,
            maxRiseFraction: 0.70 - 0.10 * h,
            // Quadratic keeps tone 0.5 at the stock 0.35; dark end floors
            // at 0.05, nearly all brown
            carrierMix: 0.05 + 0.55 * t + 0.1 * t * t,
            crashBrightness: 0.6 * t
        )
    }
}

/// Waves synthesized as a brown/pink noise carrier shaped by an endless
/// series of randomized swells: each wave rises (raised cosine), crashes,
/// and tails off, with random height and asymmetry per wave and a length
/// drawn around `waveSeconds` so waves arrive at uneven intervals. As
/// a wave crashes the carrier crossfades toward brighter noise, and a
/// constant bed level keeps distant surf audible between waves.
public struct OceanNoiseGenerator: NoiseGenerator {
    // Sits below the flat colors' RMS on purpose: the envelope adds crest,
    // so matching their loudness would push peaks past full scale
    private static let gain: Float = 1.4

    /// Timing fields apply from the next wave; the rest apply immediately
    /// (smoothed through the envelope filter).
    public var parameters: OceanParameters

    private var white: WhiteNoiseGenerator
    private var pink: PinkNoiseGenerator
    private var brown: BrownNoiseGenerator
    private var rng: SplitMix64
    private let sampleRate: Float
    private let envelopeSmoothing: Float
    private var smoothedEnvelope: Float = 0
    private var wavePosition = 0
    private var waveLength = 0
    private var wavePeak: Float = 0
    private var riseFraction: Float = 0.6

    public init(seed: UInt64? = nil, sampleRate: Double = 44_100, parameters: OceanParameters = OceanParameters()) {
        let base = SplitMix64.seedOrRandom(seed)
        rng = SplitMix64(state: base)
        white = WhiteNoiseGenerator(seed: base &+ 0x1D2F)
        pink = PinkNoiseGenerator(seed: base &+ 0x9E37)
        brown = BrownNoiseGenerator(seed: base &+ 0x79B9)
        self.parameters = parameters
        self.sampleRate = Float(sampleRate)
        // ~50 ms pole: softens wave restarts and steps from live parameter edits
        envelopeSmoothing = 1 - exp(-1 / Float(0.05 * sampleRate))
        smoothedEnvelope = parameters.bedLevel
    }

    /// Symmetric, centre-weighted draw around `waveSeconds`: most waves land
    /// near the setting while the extremes stay reachable.
    mutating func nextWaveSeconds() -> Float {
        let centre = max(0.5, parameters.waveSeconds)
        let spread = max(0, min(1, parameters.waveSecondsVariation))
        guard spread > 0 else { return centre }
        // Mean of three uniforms is bell-shaped, sd a third of the half-width
        let t = (rng.nextUniform() + rng.nextUniform() + rng.nextUniform()) / 3
        return max(0.5, centre * (1 + spread * t))
    }

    private mutating func startNextWave() {
        waveLength = max(1, Int(nextWaveSeconds() * sampleRate))
        wavePosition = 0
        wavePeak = parameters.minWavePeak
            + rng.nextUniform01() * max(0, parameters.maxWavePeak - parameters.minWavePeak)
        riseFraction = parameters.minRiseFraction
            + rng.nextUniform01() * max(0, parameters.maxRiseFraction - parameters.minRiseFraction)
        riseFraction = max(0.05, min(0.95, riseFraction))
    }

    public mutating func nextSample() -> Float {
        if wavePosition >= waveLength {
            startNextWave()
        }
        let phase = Float(wavePosition) / Float(waveLength)
        wavePosition += 1

        let swell: Float
        if phase < riseFraction {
            swell = 0.5 * (1 - cos(.pi * phase / riseFraction))
        } else {
            swell = 0.5 * (1 + cos(.pi * (phase - riseFraction) / (1 - riseFraction)))
        }
        let envelope = parameters.bedLevel + parameters.waveDepth * wavePeak * swell
        smoothedEnvelope += (envelope - smoothedEnvelope) * envelopeSmoothing

        let whiteSample = white.nextSample()
        let pinkSample = pink.nextSample()
        let brownSample = brown.nextSample()

        let mix = max(0, min(1, parameters.carrierMix))
        let carrier = (1 - mix) * brownSample + mix * pinkSample
        // Crossfade (not add) toward bright noise at the crash so loudness
        // and peak headroom stay put
        let brightness = max(0, min(1, parameters.crashBrightness)) * swell
        let bright = 0.7 * pinkSample + 0.3 * whiteSample
        let sample = carrier * (1 - brightness) + bright * brightness

        // Equal-loudness makeup: at equal RMS, brown noise carries ~2% of
        // white's A-weighted energy, so dark tones read far quieter.
        // 0.022/0.765/1 are relative A-weighted energies of brown/pink/
        // white (numeric, 48 kHz); 0.103 is the stock blend's energy so
        // default parameters keep their level. Capped at 1.2 and by flat
        // headroom (post-makeup flat RMS <= one color's baseline) so the
        // correction can't push brown-heavy peaks past unit range
        let brownWeight = (1 - brightness) * (1 - mix)
        let pinkWeight = (1 - brightness) * mix + 0.7 * brightness
        let whiteWeight = 0.3 * brightness
        let aEnergy = 0.022 * brownWeight * brownWeight
            + 0.765 * pinkWeight * pinkWeight
            + whiteWeight * whiteWeight
        let flatEnergy = brownWeight * brownWeight
            + pinkWeight * pinkWeight
            + whiteWeight * whiteWeight
        let headroomCap = 1 / max(flatEnergy, 0.25).squareRoot()
        let ideal = (0.103 / max(aEnergy, 0.001)).squareRoot()
        let loudnessMakeup = min(1.2, min(headroomCap, max(0.7, ideal)))
        return sample * loudnessMakeup * smoothedEnvelope * Self.gain
    }
}
