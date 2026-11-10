import Foundation

/// Raw synthesis controls for `OceanNoiseGenerator`. Defaults reproduce the
/// stock ocean sound; `init(wavePeriod:waveHeight:waveVariation:surge:body:wash:spray:)`
/// maps perceptual macros onto the raw fields.
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
    /// How strongly consecutive waves alternate small/large, 0...1. At 0
    /// every height is an independent draw; at 1 they strictly alternate
    /// between `minWavePeak` and `maxWavePeak`, the way sets actually arrive.
    public var peakAlternation: Float
    /// Random per-wave rise fraction range: lower = slow build, abrupt crash.
    public var minRiseFraction: Float
    public var maxRiseFraction: Float

    /// The four water layers, 0...1, where 0.5 is the reference balance and 0
    /// silences the layer. Together they replace a single tone control:
    /// `surge` is the deep swell, `body` the bulk of the water, `wash` the mid
    /// rush, `spray` the fine hiss off the top.
    public var surge: Float
    public var body: Float
    public var wash: Float
    public var spray: Float

    /// Depth of the few-Hz level churn inside each layer, 0...1. This is the
    /// restlessness of moving water; without it a layer is just noise with a
    /// slow fader on it.
    public var churnDepth: Float
    /// How far the layers are allowed to come apart, 0...1: it both blends
    /// each layer's own wave against the swell the whole sea is on and
    /// detunes the layers' periods. At 0 every layer rises in lockstep and
    /// the wave lands as one broadband gesture you can count. It takes very
    /// little - most of the measured band decorrelation comes from
    /// `churnDepth`, and the stock setting is a light touch on top of that.
    public var layerSpread: Float
    /// Extra spectral tilt at the crest, -1...1. Negative darkens as the wave
    /// breaks; positive brightens, which announces every wave and makes the
    /// cycle easy to count. It defaults to 0 because the layers already darken
    /// the crest on their own - the deep ones swell further than the bright
    /// ones, which is what surf does.
    public var crashBrightness: Float

    public init(
        bedLevel: Float = 0.45,
        waveDepth: Float = 0.55,
        waveSeconds: Float = 7.8,
        waveSecondsVariation: Float = 0.047,
        minWavePeak: Float = 0.55,
        maxWavePeak: Float = 1.0,
        peakAlternation: Float = 1.0,
        minRiseFraction: Float = 0.58,
        maxRiseFraction: Float = 0.65,
        surge: Float = 0.5,
        body: Float = 0.5,
        wash: Float = 0.5,
        spray: Float = 0.5,
        churnDepth: Float = 0.35,
        layerSpread: Float = 0.1,
        crashBrightness: Float = 0
    ) {
        self.bedLevel = bedLevel
        self.waveDepth = waveDepth
        self.waveSeconds = waveSeconds
        self.waveSecondsVariation = waveSecondsVariation
        self.minWavePeak = minWavePeak
        self.maxWavePeak = maxWavePeak
        self.peakAlternation = peakAlternation
        self.minRiseFraction = minRiseFraction
        self.maxRiseFraction = maxRiseFraction
        self.surge = surge
        self.body = body
        self.wash = wash
        self.spray = spray
        self.churnDepth = churnDepth
        self.layerSpread = layerSpread
        self.crashBrightness = crashBrightness
    }

    /// Perceptual macros, each 0...1:
    /// `wavePeriod` 0 = short frequent waves ... 1 = long slow rollers,
    /// `waveHeight` 0 = gentle swells over steady surf ... 1 = big crashes,
    /// `waveVariation` 0 = every wave the same length ... 1 = wildly irregular,
    /// and the four layer levels pass straight through.
    /// 0.5 everywhere reproduces the defaults.
    public init(
        wavePeriod: Float,
        waveHeight: Float,
        waveVariation: Float = 0.5,
        surge: Float = 0.5,
        body: Float = 0.5,
        wash: Float = 0.5,
        spray: Float = 0.5
    ) {
        let p = unitClamp(wavePeriod)
        let h = unitClamp(waveHeight)
        let v = unitClamp(waveVariation)
        self.init(
            bedLevel: 0.60 - 0.30 * h,
            waveDepth: 0.40 + 0.30 * h,
            waveSeconds: 4 + 7.6 * p,
            // Quartic keeps the midpoint near the reference's metronomic
            // spacing while leaving the top of the slider genuinely irregular
            waveSecondsVariation: 0.75 * v * v * v * v,
            minWavePeak: 0.65 - 0.20 * h,
            maxWavePeak: 0.90 + 0.20 * h,
            minRiseFraction: 0.62 - 0.08 * h,
            maxRiseFraction: 0.69 - 0.08 * h,
            surge: surge,
            body: body,
            wash: wash,
            spray: spray
        )
    }
}

/// An endless series of swells that rise (raised cosine), crest, and tail off,
/// with per-wave height, asymmetry, and length drawn around the parameters.
/// Each water layer owns one, running on its own period, so the layers drift
/// in and out of alignment instead of landing together.
struct WaveEnvelope {
    private var rng: SplitMix64
    private let sampleRate: Float
    private var position = 0
    private var length = 0
    private var peak: Float = 0
    private var riseFraction: Float = 0.6
    private var wantsTallWave = false

    /// Multiplies every length draw, so sibling layers run at related but
    /// different periods.
    var periodScale: Float = 1

    init(seed: UInt64, sampleRate: Float) {
        rng = SplitMix64(state: seed)
        self.sampleRate = sampleRate
    }

    /// Symmetric, centre-weighted draw around `waveSeconds`: most waves land
    /// near the setting while the extremes stay reachable.
    mutating func nextWaveSeconds(_ parameters: OceanParameters) -> Float {
        let centre = max(0.5, parameters.waveSeconds)
        let spread = unitClamp(parameters.waveSecondsVariation)
        guard spread > 0 else { return centre }
        // Mean of three uniforms is bell-shaped, sd a third of the half-width
        let t = (rng.nextUniform() + rng.nextUniform() + rng.nextUniform()) / 3
        return max(0.5, centre * (1 + spread * t))
    }

    private mutating func startNextWave(_ parameters: OceanParameters) {
        length = max(1, Int(nextWaveSeconds(parameters) * periodScale * sampleRate))
        position = 0

        let low = parameters.minWavePeak
        let span = max(0, parameters.maxWavePeak - parameters.minWavePeak)
        let drawn = low + rng.nextUniform01() * span
        let alternating = wantsTallWave ? parameters.maxWavePeak : parameters.minWavePeak
        peak = drawn + (alternating - drawn) * unitClamp(parameters.peakAlternation)
        wantsTallWave.toggle()

        riseFraction = parameters.minRiseFraction
            + rng.nextUniform01() * max(0, parameters.maxRiseFraction - parameters.minRiseFraction)
        riseFraction = max(0.05, min(0.95, riseFraction))
    }

    /// Advances `samples` frames and returns the envelope. Called at control
    /// rate - a seconds-long swell needs nothing finer, and the caller smooths
    /// the steps away.
    mutating func advance(_ samples: Int, parameters: OceanParameters) -> Float {
        if position >= length {
            startNextWave(parameters)
        }
        let phase = Float(position) / Float(length)
        position += samples

        let swell: Float
        if phase < riseFraction {
            swell = 0.5 * (1 - cos(.pi * phase / riseFraction))
        } else {
            swell = 0.5 * (1 + cos(.pi * (phase - riseFraction) / (1 - riseFraction)))
        }
        return parameters.bedLevel + parameters.waveDepth * peak * swell
    }
}

/// One band of water: a 4-pole bandpass fed its own noise, scaled by its own
/// wave envelope and its own few-Hz churn.
struct WaterLayer {
    /// Input gain that places this band against the others. Fitted offline to
    /// the reference spectrum; `Scripts/ocean_match.py` checks the result.
    let drive: Float
    /// A-weighted output energy at that drive, normalized so the four layers
    /// sum to 1 at the reference balance. Holds loudness steady as the layer
    /// levels move.
    let aEnergy: Float
    /// Unweighted output energy, same normalization. A-weighting barely sees
    /// the deepest layer, so boosting it would sail past full scale while the
    /// A-weighted total hardly moved; this is what bounds that.
    let flatEnergy: Float
    /// How far, in octaves, this layer moves when the crest tilts the balance.
    let tiltWeight: Float
    /// Per-layer scaling of `churnDepth` and of the wave swell.
    let churnScale: Float
    let depthScale: Float
    /// Mean of `1 - depthScale * (1 - envelope)` over a wave, so a shallower
    /// layer can be scaled back to the level the spectral fit assumed.
    let depthMakeup: Float

    private var first = StateVariableFilter()
    private var second = StateVariableFilter()
    private var wave: WaveEnvelope
    private var churn: Wander
    private var gain: Float = 0
    private var target: Float = 0

    init(
        cutoff: Float,
        damping: Float,
        drive: Float,
        aEnergy: Float,
        flatEnergy: Float,
        tiltWeight: Float,
        churnScale: Float,
        depthScale: Float,
        seed: UInt64,
        sampleRate: Float,
        controlRate: Float
    ) {
        self.drive = drive
        self.aEnergy = aEnergy
        self.flatEnergy = flatEnergy
        self.tiltWeight = tiltWeight
        self.churnScale = churnScale
        self.depthScale = depthScale
        // Mean envelope over a raised-cosine swell is bed + depth * peak / 2;
        // 0.66 is that for the stock parameters
        depthMakeup = 1 / (1 - depthScale * (1 - 0.66))
        wave = WaveEnvelope(seed: seed, sampleRate: sampleRate)
        // Stepped once per control block, so it is built at the control rate
        // and its hold and glide stay in real seconds. 0.08-0.5 s puts the
        // churn in the 2-10 Hz band, where moving water lives.
        churn = Wander(
            seed: seed &+ 0x5BD1,
            sampleRate: controlRate,
            minHoldSeconds: 0.08,
            maxHoldSeconds: 0.5,
            glideSeconds: 0.05
        )
        first.set(cutoff: cutoff, damping: damping, sampleRate: sampleRate)
        second.set(cutoff: cutoff, damping: damping, sampleRate: sampleRate)
    }

    mutating func nextWaveSeconds(_ parameters: OceanParameters) -> Float {
        wave.nextWaveSeconds(parameters)
    }

    mutating func setPeriodScale(_ scale: Float) {
        wave.periodScale = scale
    }

    /// Advances this layer's own wave by one control block.
    mutating func advanceEnvelope(_ parameters: OceanParameters, samples: Int) -> Float {
        wave.advance(samples, parameters: parameters)
    }

    /// Folds the (already blended) envelope, the churn, and the level into one
    /// target gain for the next block.
    mutating func applyEnvelope(_ envelope: Float, _ parameters: OceanParameters, level: Float) {
        let swell = max(0, 1 - depthScale * (1 - envelope)) * depthMakeup
        let swing = unitClamp(parameters.churnDepth) * churnScale
        let churned = max(0, 1 + swing * (churn.next() * 2 - 1))
        target = level * swell * churned
    }

    mutating func applyTilt(_ octaves: Float) {
        target *= exp2(octaves * tiltWeight)
    }

    mutating func process(_ noise: Float, smoothing: Float) -> Float {
        gain += (target - gain) * smoothing
        return second.processBand(first.processBand(noise * drive)) * gain
    }
}

/// Four independently modulated bands of water summed into one mono stream.
///
/// A single broadband carrier under one envelope makes every frequency swell
/// at the same instant, which is what turns a wave into a countable event.
/// Here each band carries its own wave period, its own few-Hz churn, and its
/// own share of the crest tilt, so the water is never doing only one thing.
public struct OceanNoiseGenerator: NoiseGenerator {
    // The swell and the crest tilt are refreshed every 32 samples (~0.7 ms),
    // far finer than the seconds-long envelopes they track and cheap enough
    // to keep cos and exp2 out of the per-sample path
    private static let controlInterval = 32
    private static let gain: Float = 3.3
    /// Trims the top octaves to the reference's band limit. Three poles at
    /// this cutoff give the ~-18 dB/octave cliff measured above 3 kHz.
    private static let topCutoff: Float = 2_877
    /// Period multipliers at `layerSpread` 1. Body stays at 1 so
    /// `nextWaveSeconds()` reports the draw the parameters describe.
    private static let periodOffsets: (Float, Float, Float, Float) = (-0.5, 0, 0.6, 1.2)

    public var parameters: OceanParameters

    private var rng: SplitMix64
    private var surge: WaterLayer
    private var body: WaterLayer
    private var wash: WaterLayer
    private var spray: WaterLayer
    private var topA = OnePoleLowpass()
    private var topB = OnePoleLowpass()
    private var topC = OnePoleLowpass()
    private let smoothing: Float

    private var derivedFor: OceanParameters?
    private var surgeLevel: Float = 0
    private var bodyLevel: Float = 0
    private var washLevel: Float = 0
    private var sprayLevel: Float = 0
    private var controlCountdown = 0

    public init(seed: UInt64? = nil, sampleRate: Double = 44_100, parameters: OceanParameters = OceanParameters()) {
        let base = SplitMix64.seedOrRandom(seed)
        let rate = Float(sampleRate)
        let controlRate = rate / Float(Self.controlInterval)
        rng = SplitMix64(state: base &+ 0x1D2F)
        surge = WaterLayer(
            cutoff: 85.1, damping: 2.00, drive: 1.0000, aEnergy: 0.027704,
            flatEnergy: 0.160678,
            tiltWeight: -1.5, churnScale: 0.35, depthScale: 1.0,
            seed: base &+ 0x9E37, sampleRate: rate, controlRate: controlRate
        )
        body = WaterLayer(
            cutoff: 286.1, damping: 1.04, drive: 0.4454, aEnergy: 0.623772,
            flatEnergy: 0.737888,
            tiltWeight: -0.5, churnScale: 0.55, depthScale: 0.85,
            seed: base &+ 0x79B9, sampleRate: rate, controlRate: controlRate
        )
        wash = WaterLayer(
            cutoff: 988.2, damping: 0.80, drive: 0.0582, aEnergy: 0.215754,
            flatEnergy: 0.067787,
            tiltWeight: 0.8, churnScale: 1.0, depthScale: 0.6,
            seed: base &+ 0xC2B2, sampleRate: rate, controlRate: controlRate
        )
        spray = WaterLayer(
            cutoff: 3_258.9, damping: 1.73, drive: 0.2044, aEnergy: 0.132770,
            flatEnergy: 0.033647,
            tiltWeight: 1.5, churnScale: 0.9, depthScale: 0.7,
            seed: base &+ 0x165F, sampleRate: rate, controlRate: controlRate
        )
        let k = OnePoleLowpass.coefficient(cutoff: Self.topCutoff, sampleRate: rate)
        topA.coefficient = k
        topB.coefficient = k
        topC.coefficient = k
        self.parameters = parameters
        // ~20 ms pole: smooths the control-rate steps and any live edit
        smoothing = 1 - exp(-1 / Float(0.02 * sampleRate))
    }

    /// The wave length the current parameters describe, as the body layer
    /// draws it.
    mutating func nextWaveSeconds() -> Float {
        body.nextWaveSeconds(parameters)
    }

    private mutating func refreshDerived() {
        // Each slider is a fader on its layer, 0.5 being the reference
        // balance; squaring gives a usable taper and silences the layer at 0
        func fader(_ value: Float) -> Float {
            let v = unitClamp(value) * 2
            return v * v
        }
        surgeLevel = fader(parameters.surge)
        bodyLevel = fader(parameters.body)
        washLevel = fader(parameters.wash)
        sprayLevel = fader(parameters.spray)

        // The layers are a balance, not four volumes: hold the A-weighted
        // total where the reference balance puts it, so moving a slider
        // changes the character of the water rather than how loud it is
        func total(_ energy: (WaterLayer) -> Float) -> Float {
            surgeLevel * surgeLevel * energy(surge)
                + bodyLevel * bodyLevel * energy(body)
                + washLevel * washLevel * energy(wash)
                + sprayLevel * sprayLevel * energy(spray)
        }
        let weighted = total { $0.aEnergy }
        let flat = total { $0.flatEnergy }
        if weighted > 0 && flat > 0 {
            // 4 is exactly the correction a uniform 0.25 needs, so the top
            // three quarters of the sliders rebalance at a steady level and
            // only the bottom quarter fades the water out
            let makeup = min(4, min((1 / weighted).squareRoot(), (1 / flat).squareRoot()))
            surgeLevel *= makeup
            bodyLevel *= makeup
            washLevel *= makeup
            sprayLevel *= makeup
        }

        let spread = unitClamp(parameters.layerSpread)
        surge.setPeriodScale(1 + Self.periodOffsets.0 * spread)
        body.setPeriodScale(1 + Self.periodOffsets.1 * spread)
        wash.setPeriodScale(1 + Self.periodOffsets.2 * spread)
        spray.setPeriodScale(1 + Self.periodOffsets.3 * spread)

        derivedFor = parameters
        controlCountdown = 0
    }

    private mutating func updateControlRate() {
        let step = Self.controlInterval
        let ownSurge = surge.advanceEnvelope(parameters, samples: step)
        let shared = body.advanceEnvelope(parameters, samples: step)
        let ownWash = wash.advanceEnvelope(parameters, samples: step)
        let ownSpray = spray.advanceEnvelope(parameters, samples: step)

        // Real water does not swell band by band in total independence, nor
        // all at once: each layer is part its own wave, part the swell the
        // whole sea is on. `layerSpread` is that mix, and it sets directly how
        // far the band envelopes are allowed to come apart.
        let spread = unitClamp(parameters.layerSpread)
        func blend(_ own: Float) -> Float { shared + (own - shared) * spread }
        surge.applyEnvelope(blend(ownSurge), parameters, level: surgeLevel)
        body.applyEnvelope(shared, parameters, level: bodyLevel)
        wash.applyEnvelope(blend(ownWash), parameters, level: washLevel)
        spray.applyEnvelope(blend(ownSpray), parameters, level: sprayLevel)

        // Tilt tracks how far the water has risen above its bed, so the crest
        // changes colour without changing the level underneath it
        let bed = unitClamp(parameters.bedLevel)
        let risen = unitClamp((shared - bed) / max(0.01, 1 - bed))
        let octaves = max(-1, min(1, parameters.crashBrightness)) * risen
        surge.applyTilt(octaves)
        body.applyTilt(octaves)
        wash.applyTilt(octaves)
        spray.applyTilt(octaves)
    }

    public mutating func nextSample() -> Float {
        if derivedFor != parameters {
            refreshDerived()
        }
        if controlCountdown == 0 {
            updateControlRate()
            controlCountdown = Self.controlInterval
        }
        controlCountdown -= 1

        // Independent noise per layer: one shared draw would make the
        // overlapping band skirts sum coherently and comb where they meet
        var sample = surge.process(rng.nextUniform(), smoothing: smoothing)
        sample += body.process(rng.nextUniform(), smoothing: smoothing)
        sample += wash.process(rng.nextUniform(), smoothing: smoothing)
        sample += spray.process(rng.nextUniform(), smoothing: smoothing)

        return topC.process(topB.process(topA.process(sample))) * Self.gain
    }
}
