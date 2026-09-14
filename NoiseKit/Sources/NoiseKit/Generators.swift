public protocol NoiseGenerator {
    mutating func nextSample() -> Float
}

extension NoiseGenerator {
    public mutating func render(into buffer: UnsafeMutableBufferPointer<Float>) {
        for i in buffer.indices {
            buffer[i] = nextSample()
        }
    }
}

// All generators are normalized to roughly the same RMS (~0.2, -14 dBFS)
// so switching colors doesn't jump in loudness. 0.2 leaves ~5 sigma of
// crest headroom, keeping peaks under full scale.
enum Loudness {
    static let targetRMS: Float = 0.2
}

struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUniform() -> Float {
        Float(next() >> 40) * (2.0 / 16_777_216.0) - 1.0
    }

    mutating func nextUniform01() -> Float {
        Float(next() >> 40) * (1.0 / 16_777_216.0)
    }

    static func seedOrRandom(_ seed: UInt64?) -> UInt64 {
        seed ?? UInt64.random(in: .min ... .max)
    }
}

public struct WhiteNoiseGenerator: NoiseGenerator {
    // Uniform noise in [-1, 1) has RMS 1/sqrt(3)
    private static let gain: Float = Loudness.targetRMS * 1.7320508

    private var rng: SplitMix64

    public init(seed: UInt64? = nil) {
        rng = SplitMix64(state: SplitMix64.seedOrRandom(seed))
    }

    public mutating func nextSample() -> Float {
        rng.nextUniform() * Self.gain
    }
}

public struct PinkNoiseGenerator: NoiseGenerator {
    // The filter below outputs RMS ~1.77 for unit uniform input; this
    // brings it to Loudness.targetRMS
    private static let gain: Float = 0.113

    private var rng: SplitMix64
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0
    private var b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0

    public init(seed: UInt64? = nil) {
        rng = SplitMix64(state: SplitMix64.seedOrRandom(seed))
    }

    // Paul Kellet's refined -3 dB/octave filter (accurate within
    // +/-0.05 dB above 9.2 Hz at 44.1 kHz)
    public mutating func nextSample() -> Float {
        let w = rng.nextUniform()
        b0 = 0.99886 * b0 + w * 0.0555179
        b1 = 0.99332 * b1 + w * 0.0750759
        b2 = 0.96900 * b2 + w * 0.1538520
        b3 = 0.86650 * b3 + w * 0.3104856
        b4 = 0.55000 * b4 + w * 0.5329522
        b5 = -0.7616 * b5 - w * 0.0168980
        let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
        b6 = w * 0.115926
        return pink * Self.gain
    }
}

public struct BrownNoiseGenerator: NoiseGenerator {
    // Leaky integrator: cutoff ~7 Hz at 44.1 kHz, -6 dB/octave above it.
    // AR(1) stationary RMS is 0.02/sqrt(3(1-leak^2)) ~= 0.258; gain brings
    // that to Loudness.targetRMS
    private static let leak: Float = 0.999
    private static let drive: Float = 0.02
    private static let gain: Float = 0.775

    private var rng: SplitMix64
    private var level: Float = 0

    public init(seed: UInt64? = nil) {
        rng = SplitMix64(state: SplitMix64.seedOrRandom(seed))
    }

    public mutating func nextSample() -> Float {
        level = level * Self.leak + rng.nextUniform() * Self.drive
        return level * Self.gain
    }
}
