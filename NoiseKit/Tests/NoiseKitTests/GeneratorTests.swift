import XCTest
@testable import NoiseKit

final class GeneratorTests: XCTestCase {
    private func samples(_ color: NoiseType, count: Int, seed: UInt64 = 42) -> [Float] {
        var generator = color.makeGenerator(seed: seed)
        return (0..<count).map { _ in generator.nextSample() }
    }

    func testDeterministicForSameSeed() {
        for color in NoiseType.allCases {
            XCTAssertEqual(
                samples(color, count: 1_000, seed: 7),
                samples(color, count: 1_000, seed: 7),
                "\(color) should be deterministic for a fixed seed"
            )
            XCTAssertNotEqual(
                samples(color, count: 1_000, seed: 7),
                samples(color, count: 1_000, seed: 8),
                "\(color) should differ across seeds"
            )
        }
    }

    func testRandomSeedByDefault() {
        for color in NoiseType.allCases {
            var a = color.makeGenerator()
            var b = color.makeGenerator()
            let sa = (0..<100).map { _ in a.nextSample() }
            let sb = (0..<100).map { _ in b.nextSample() }
            XCTAssertNotEqual(sa, sb, "\(color) with default seed should not repeat")
        }
    }

    func testOutputStaysWithinUnitRange() {
        for color in NoiseType.allCases {
            let s = samples(color, count: 1_000_000)
            let peak = s.map(abs).max() ?? 0
            XCTAssertLessThanOrEqual(peak, 1.0, "\(color) peak \(peak) exceeds full scale")
        }
    }

    func testLoudnessIsNormalizedAcrossColors() {
        for color in [NoiseType.white, .pink, .brown] {
            let s = samples(color, count: 1_000_000)
            let mean = s.reduce(0, +) / Float(s.count)
            let rms = (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
            XCTAssertEqual(mean, 0, accuracy: 0.01, "\(color) should have zero DC offset")
            XCTAssertEqual(rms, Loudness.targetRMS, accuracy: 0.05, "\(color) RMS \(rms) off target")
        }
    }

    // Ocean is amplitude-modulated, so its long-run RMS sits below the flat
    // colors (crest headroom) and needs a longer window to settle
    func testOceanLoudnessAndModulation() {
        let s = samples(.ocean, count: 4_000_000)
        let mean = s.reduce(0, +) / Float(s.count)
        let rms = (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
        XCTAssertEqual(mean, 0, accuracy: 0.01, "ocean should have zero DC offset")
        XCTAssertGreaterThan(rms, 0.07, "ocean RMS \(rms) too quiet")
        XCTAssertLessThan(rms, 0.19, "ocean RMS \(rms) too loud")

        let chunkSize = 44_100
        let chunkRMS = stride(from: 0, to: s.count, by: chunkSize).map { start -> Float in
            let chunk = s[start..<min(start + chunkSize, s.count)]
            return (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        }
        let quietest = chunkRMS.min() ?? 0
        let loudest = chunkRMS.max() ?? 0
        XCTAssertGreaterThan(quietest, 0, "bed level should keep surf audible between waves")
        XCTAssertGreaterThan(loudest, quietest * 2, "waves should visibly swell over the bed")
    }

    func testOceanStaysBoundedAcrossMacroCorners() {
        var corners: [(Float, Float, Float, Float)] = [(0.5, 0.5, 0.5, 0.5)]
        for p: Float in [0, 1] {
            for h: Float in [0, 1] {
                for t: Float in [0, 1] {
                    for v: Float in [0, 1] {
                        corners.append((p, h, t, v))
                    }
                }
            }
        }
        for (period, height, tone, variation) in corners {
            let params = OceanParameters(
                wavePeriod: period,
                waveHeight: height,
                tone: tone,
                waveVariation: variation
            )
            var generator = OceanNoiseGenerator(seed: 99, parameters: params)
            var sumSquares: Float = 0
            var peak: Float = 0
            for _ in 0..<2_000_000 {
                let s = generator.nextSample()
                sumSquares += s * s
                peak = max(peak, abs(s))
            }
            let rms = (sumSquares / 2_000_000).squareRoot()
            let label = "ocean(period:\(period) height:\(height) tone:\(tone) variation:\(variation))"
            XCTAssertLessThanOrEqual(peak, 1.0, "\(label) peak \(peak)")
            XCTAssertGreaterThan(rms, 0.04, "\(label) RMS \(rms) too quiet")
            XCTAssertLessThan(rms, 0.22, "\(label) RMS \(rms) too loud")
        }
    }

    func testOceanMacroMidpointMatchesDefaults() {
        let macro = OceanParameters(wavePeriod: 0.5, waveHeight: 0.5, tone: 0.5, waveVariation: 0.5)
        let defaults = OceanParameters()
        XCTAssertEqual(macro.bedLevel, defaults.bedLevel, accuracy: 0.01)
        XCTAssertEqual(macro.waveDepth, defaults.waveDepth, accuracy: 0.01)
        XCTAssertEqual(macro.waveSeconds, defaults.waveSeconds, accuracy: 1.0)
        XCTAssertEqual(macro.waveSecondsVariation, defaults.waveSecondsVariation, accuracy: 0.01)
        XCTAssertEqual(macro.carrierMix, defaults.carrierMix, accuracy: 0.01)
        XCTAssertEqual(macro.crashBrightness, defaults.crashBrightness, accuracy: 0.01)
    }

    func testOceanWaveLengthsClusterAroundTheSetting() {
        let params = OceanParameters(waveSeconds: 10, waveSecondsVariation: 0.4)
        var generator = OceanNoiseGenerator(seed: 7, parameters: params)
        let draws = (0..<4000).map { _ in generator.nextWaveSeconds() }

        for seconds in draws {
            XCTAssertGreaterThanOrEqual(seconds, 6 - 0.001, "draw \(seconds) below the spread")
            XCTAssertLessThanOrEqual(seconds, 14 + 0.001, "draw \(seconds) above the spread")
        }

        let mean = draws.reduce(0, +) / Float(draws.count)
        XCTAssertEqual(mean, 10, accuracy: 0.2, "draws should centre on waveSeconds")

        // A uniform draw would put half the mass in the middle half; a
        // centre-weighted one puts far more
        let middleHalf = draws.filter { $0 > 8 && $0 < 12 }.count
        XCTAssertGreaterThan(
            Float(middleHalf) / Float(draws.count), 0.6,
            "draws should cluster near the setting, not spread uniformly"
        )
    }

    func testOceanZeroVariationGivesIdenticalWaveLengths() {
        let params = OceanParameters(waveSeconds: 8, waveSecondsVariation: 0)
        var generator = OceanNoiseGenerator(seed: 7, parameters: params)
        for _ in 0..<50 {
            XCTAssertEqual(generator.nextWaveSeconds(), 8)
        }
    }

    func testRenderIntoBufferMatchesNextSample() {
        var a = PinkNoiseGenerator(seed: 3)
        var b = PinkNoiseGenerator(seed: 3)
        let expected = (0..<512).map { _ in a.nextSample() }
        var buffer = [Float](repeating: 0, count: 512)
        buffer.withUnsafeMutableBufferPointer { b.render(into: $0) }
        XCTAssertEqual(buffer, expected)
    }
}
