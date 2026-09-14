import XCTest
@testable import NoiseKit

// At 44.1 kHz with 8192-point segments each bin is ~5.4 Hz
private let binsPerHz = Double(WelchAnalyzer.segmentLength) / 44_100.0

final class NatureTests: XCTestCase {
    private func macroCorners() -> [(Float, Float)] {
        [(0.5, 0.5), (0, 0), (0, 1), (1, 0), (1, 1)]
    }

    private func assertBounded(_ generator: inout some NoiseGenerator, label: String, minRMS: Float = 0.04, count: Int = 2_000_000) {
        var sumSquares: Float = 0
        var peak: Float = 0
        for _ in 0..<count {
            let s = generator.nextSample()
            sumSquares += s * s
            peak = max(peak, abs(s))
        }
        let rms = (sumSquares / Float(count)).squareRoot()
        XCTAssertLessThanOrEqual(peak, 1.0, "\(label) peak \(peak)")
        XCTAssertGreaterThan(rms, minRMS, "\(label) RMS \(rms) too quiet")
        XCTAssertLessThan(rms, 0.22, "\(label) RMS \(rms) too loud")
    }

    func testWindStaysBoundedAcrossMacroCorners() {
        for (gustiness, tone) in macroCorners() {
            var generator = WindNoiseGenerator(seed: 7, parameters: WindParameters(gustiness: gustiness, tone: tone))
            assertBounded(&generator, label: "wind(gustiness:\(gustiness) tone:\(tone))")
        }
    }

    func testRainStaysBoundedAcrossMacroCorners() {
        for (intensity, surface) in macroCorners() {
            for (rate, dropSize) in macroCorners() {
                var generator = RainNoiseGenerator(
                    seed: 7,
                    parameters: RainParameters(intensity: intensity, surface: surface, rate: rate, dropSize: dropSize)
                )
                assertBounded(
                    &generator,
                    label: "rain(intensity:\(intensity) surface:\(surface) rate:\(rate) drop:\(dropSize))"
                )
            }
        }
    }

    func testTreesStaysBoundedAcrossMacroCorners() {
        for (breeze, density) in macroCorners() {
            for leafSize: Float in [0, 0.5, 1] {
                var generator = TreesNoiseGenerator(
                    seed: 7,
                    parameters: TreesParameters(breeze: breeze, density: density, leafSize: leafSize)
                )
                // Low breeze legitimately includes near-silent lulls, so the
                // loudness floor only applies once the canopy is moving
                assertBounded(
                    &generator,
                    label: "trees(breeze:\(breeze) density:\(density) leaf:\(leafSize))",
                    minRMS: breeze > 0 ? 0.03 : 0.003
                )
            }
        }
    }

    private func bandRatio(of generator: any NoiseGenerator, lowBand: Range<Int>, highBand: Range<Int>) -> Double {
        var iterator = GeneratorSampleIterator(generator: generator)
        guard let power = WelchAnalyzer.averagedPowerSpectrum(samples: &iterator, segmentCount: 48) else {
            XCTFail("could not create FFT setup")
            return .nan
        }
        return WelchAnalyzer.bandPower(power, bins: highBand)
            / WelchAnalyzer.bandPower(power, bins: lowBand)
    }

    func testWindEnergySitsLow() {
        // Wind should concentrate energy below ~1 kHz, well above 4 kHz's
        let below1k = Int(1_000 * binsPerHz)
        let above4k = Int(4_000 * binsPerHz)
        let ratio = bandRatio(
            of: WindNoiseGenerator(seed: 11),
            lowBand: 8..<below1k,
            highBand: above4k..<(WelchAnalyzer.segmentLength / 2)
        )
        XCTAssertLessThan(ratio, 0.05, "wind high/low band power ratio \(ratio) - sounds too hissy")
    }

    private struct Bands {
        /// Where the body of a nature sound belongs
        var lowMid: Double
        /// The 2-5 kHz region the ear is most sensitive to
        var presence: Double
        /// The top octaves, which read as sizzle rather than texture
        var top: Double
    }

    private func bands(of generator: any NoiseGenerator) -> Bands? {
        var iterator = GeneratorSampleIterator(generator: generator)
        guard let power = WelchAnalyzer.averagedPowerSpectrum(samples: &iterator, segmentCount: 48) else {
            XCTFail("could not create FFT setup")
            return nil
        }
        func band(_ low: Double, _ high: Double) -> Double {
            WelchAnalyzer.bandPower(power, bins: Int(low * binsPerHz)..<Int(high * binsPerHz))
        }
        return Bands(lowMid: band(400, 1_600), presence: band(2_000, 5_000), top: band(9_000, 18_000))
    }

    /// Rain and foliage are both made of impacts spread over octaves. Pile
    /// those impacts into one narrow band and the sound stops being weather
    /// and becomes hiss - which is what happens when every impact excites a
    /// single resonator instead of a bank. The damage lands in 2-5 kHz,
    /// where the ear is most sensitive, so that is what to pin down.
    private func assertSpreadEnergy(
        of generator: any NoiseGenerator,
        label: String,
        presenceRange: ClosedRange<Double>,
        topLimit: Double
    ) {
        guard let bands = bands(of: generator) else { return }
        let presence = bands.presence / bands.lowMid
        XCTAssertLessThanOrEqual(
            presence, presenceRange.upperBound,
            "\(label) presence/low-mid \(presence) - sounds harsh"
        )
        XCTAssertGreaterThanOrEqual(
            presence, presenceRange.lowerBound,
            "\(label) presence/low-mid \(presence) - sounds muffled"
        )
        let top = bands.top / bands.lowMid
        XCTAssertLessThan(top, topLimit, "\(label) top-octave/low-mid \(top) - sounds sizzly")
    }

    func testRainSpreadsEnergyInsteadOfSpikingThePresenceBand() {
        for (intensity, surface) in macroCorners() {
            assertSpreadEnergy(
                of: RainNoiseGenerator(
                    seed: 11,
                    parameters: RainParameters(intensity: intensity, surface: surface, rate: 0.5, dropSize: 0.5)
                ),
                label: "rain(intensity:\(intensity) surface:\(surface))",
                presenceRange: 0.08...1.1,
                topLimit: 0.02
            )
        }
    }

    func testTreesSpreadEnergyInsteadOfSpikingThePresenceBand() {
        for (breeze, density) in macroCorners() {
            for leafSize: Float in [0, 0.5, 1] {
                assertSpreadEnergy(
                    of: TreesNoiseGenerator(
                        seed: 11,
                        parameters: TreesParameters(breeze: breeze, density: density, leafSize: leafSize)
                    ),
                    label: "trees(breeze:\(breeze) density:\(density) leaf:\(leafSize))",
                    presenceRange: 0.04...0.9,
                    topLimit: 0.008
                )
            }
        }
    }

    private func chunkRMSSwing(_ generator: inout some NoiseGenerator, seconds: Int) -> (quietest: Float, loudest: Float) {
        let chunkSize = 44_100
        var quietest = Float.greatestFiniteMagnitude
        var loudest: Float = 0
        for _ in 0..<seconds {
            var sumSquares: Float = 0
            for _ in 0..<chunkSize {
                let s = generator.nextSample()
                sumSquares += s * s
            }
            let rms = (sumSquares / Float(chunkSize)).squareRoot()
            quietest = min(quietest, rms)
            loudest = max(loudest, rms)
        }
        return (quietest, loudest)
    }

    func testWindGustsActuallyGust() {
        var generator = WindNoiseGenerator(seed: 21, parameters: WindParameters(gustiness: 1, tone: 0.5))
        let swing = chunkRMSSwing(&generator, seconds: 60)
        XCTAssertGreaterThan(swing.quietest, 0, "wind should never fully die out")
        XCTAssertGreaterThan(
            swing.loudest, swing.quietest * 1.8,
            "gusts at full gustiness should visibly swell (quiet \(swing.quietest), loud \(swing.loudest))"
        )
    }

    func testTreesFlutterModulates() {
        var generator = TreesNoiseGenerator(seed: 21, parameters: TreesParameters(breeze: 1, density: 0))
        let swing = chunkRMSSwing(&generator, seconds: 60)
        XCTAssertGreaterThan(swing.quietest, 0, "rustle should never fully die out")
        XCTAssertGreaterThan(
            swing.loudest, swing.quietest * 1.5,
            "sparse flutter should visibly modulate (quiet \(swing.quietest), loud \(swing.loudest))"
        )
    }
}
