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
    }

    /// The swell has to be deep enough to hear and shallow enough that the
    /// wave stops being an event you can count. The reference swings 2.0x
    /// between its quietest and loudest second; the bounds either side of
    /// that are what keep this honest in both directions.
    func testOceanSwellsLikeTheReference() {
        var generator = OceanNoiseGenerator(seed: 21)
        let swing = chunkRMSSwing(&generator, seconds: 120)
        XCTAssertGreaterThan(swing.quietest, 0, "the bed should keep surf audible between waves")
        let ratio = swing.loudest / swing.quietest
        XCTAssertGreaterThan(ratio, 1.6, "swell ratio \(ratio) - waves barely rise above the bed")
        XCTAssertLessThan(ratio, 3.2, "swell ratio \(ratio) - every wave lands as a countable event")
    }

    func testOceanStaysBoundedAcrossMacroCorners() {
        // Seven macros will not sweep cartesian at two million samples each.
        // Centre, then each macro alone at both ends, then all-min and
        // all-max, where the layer balance has to work hardest.
        let names = ["period", "height", "variation", "surge", "body", "wash", "spray"]
        var corners: [(label: String, macros: [Float])] = [("centre", Array(repeating: 0.5, count: names.count))]
        for index in names.indices {
            for value in [Float(0), 1] {
                var macros = [Float](repeating: 0.5, count: names.count)
                macros[index] = value
                corners.append(("\(names[index]):\(value)", macros))
            }
        }
        corners.append(("all-min", Array(repeating: 0, count: names.count)))
        corners.append(("all-max", Array(repeating: 1, count: names.count)))

        for (label, macros) in corners {
            let params = OceanParameters(
                wavePeriod: macros[0],
                waveHeight: macros[1],
                waveVariation: macros[2],
                surge: macros[3],
                body: macros[4],
                wash: macros[5],
                spray: macros[6]
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
            XCTAssertLessThanOrEqual(peak, 1.0, "ocean(\(label)) peak \(peak)")
            if params.surge == 0 && params.body == 0 && params.wash == 0 && params.spray == 0 {
                // Every layer off is silence, which is the honest answer
                XCTAssertEqual(rms, 0, accuracy: 1e-6, "ocean(\(label)) should be silent")
            } else {
                XCTAssertGreaterThan(rms, 0.04, "ocean(\(label)) RMS \(rms) too quiet")
                XCTAssertLessThan(rms, 0.22, "ocean(\(label)) RMS \(rms) too loud")
            }
        }
    }

    /// The four layer sliders are a balance, not four volumes: any setting
    /// where they share a common scale has to land at the same loudness.
    func testOceanLayerSlidersHoldLoudness() {
        func rms(_ level: Float) -> Float {
            var generator = OceanNoiseGenerator(seed: 5, parameters: OceanParameters(
                wavePeriod: 0.5, waveHeight: 0.5, waveVariation: 0.5,
                surge: level, body: level, wash: level, spray: level
            ))
            var sumSquares: Float = 0
            for _ in 0..<1_000_000 {
                let s = generator.nextSample()
                sumSquares += s * s
            }
            return (sumSquares / 1_000_000).squareRoot()
        }
        let reference = rms(0.5)
        for level: Float in [0.25, 0.75, 1] {
            XCTAssertEqual(
                rms(level), reference, accuracy: reference * 0.1,
                "layers at \(level) should sit at the same loudness as the reference balance"
            )
        }
    }

    func testOceanMacroMidpointMatchesDefaults() {
        let macro = OceanParameters(wavePeriod: 0.5, waveHeight: 0.5, waveVariation: 0.5)
        let defaults = OceanParameters()
        XCTAssertEqual(macro.bedLevel, defaults.bedLevel, accuracy: 0.01)
        XCTAssertEqual(macro.waveDepth, defaults.waveDepth, accuracy: 0.01)
        XCTAssertEqual(macro.waveSeconds, defaults.waveSeconds, accuracy: 1.0)
        XCTAssertEqual(macro.waveSecondsVariation, defaults.waveSecondsVariation, accuracy: 0.01)
        XCTAssertEqual(macro.surge, defaults.surge, accuracy: 0.01)
        XCTAssertEqual(macro.body, defaults.body, accuracy: 0.01)
        XCTAssertEqual(macro.wash, defaults.wash, accuracy: 0.01)
        XCTAssertEqual(macro.spray, defaults.spray, accuracy: 0.01)
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
