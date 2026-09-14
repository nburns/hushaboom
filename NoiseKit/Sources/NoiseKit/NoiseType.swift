import Foundation

public enum NoiseType: String, CaseIterable, Identifiable, Sendable {
    case white
    case pink
    case brown
    case ocean
    case wind
    case rain
    case trees

    public var id: String { rawValue }

    public var displayName: String { rawValue.capitalized }

    public func makeGenerator(seed: UInt64? = nil, sampleRate: Double = 44_100) -> any NoiseGenerator {
        switch self {
        case .white: return WhiteNoiseGenerator(seed: seed)
        case .pink: return PinkNoiseGenerator(seed: seed)
        case .brown: return BrownNoiseGenerator(seed: seed)
        case .ocean: return OceanNoiseGenerator(seed: seed, sampleRate: sampleRate)
        case .wind: return WindNoiseGenerator(seed: seed, sampleRate: sampleRate)
        case .rain: return RainNoiseGenerator(seed: seed, sampleRate: sampleRate)
        case .trees: return TreesNoiseGenerator(seed: seed, sampleRate: sampleRate)
        }
    }
}
