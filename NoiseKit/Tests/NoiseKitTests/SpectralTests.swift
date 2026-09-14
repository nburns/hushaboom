import XCTest
@testable import NoiseKit

final class SpectralTests: XCTestCase {
    func testWhiteNoiseSpectralSlopeIsFlat() {
        let slope = spectralSlope(of: .white)
        XCTAssertEqual(slope, 0, accuracy: 0.5, "white noise should be ~0 dB/octave, got \(slope)")
    }

    func testPinkNoiseSpectralSlope() {
        let slope = spectralSlope(of: .pink)
        XCTAssertEqual(slope, -3.01, accuracy: 0.8, "pink noise should be ~-3 dB/octave, got \(slope)")
    }

    func testBrownNoiseSpectralSlope() {
        let slope = spectralSlope(of: .brown)
        XCTAssertEqual(slope, -6.02, accuracy: 0.8, "brown noise should be ~-6 dB/octave, got \(slope)")
    }

    // Band powers on octave-spaced bins, least-squares slope of dB vs octave
    private func spectralSlope(of color: NoiseType) -> Double {
        var iterator = GeneratorSampleIterator(generator: color.makeGenerator(seed: 12345))
        guard let power = WelchAnalyzer.averagedPowerSpectrum(samples: &iterator, segmentCount: 32) else {
            XCTFail("could not create FFT setup")
            return .nan
        }

        // Octave bands [8,16), [16,32), ..., [1024,2048): stays above the
        // brown generator's leak cutoff and below Nyquist warping.
        var octaves = [Double]()
        var bandDb = [Double]()
        var lower = 8
        var octaveIndex = 0.0
        while lower < 2_048 {
            let upper = lower * 2
            octaves.append(octaveIndex)
            bandDb.append(10 * log10(WelchAnalyzer.bandPower(power, bins: lower..<upper)))
            lower = upper
            octaveIndex += 1
        }

        let count = Double(octaves.count)
        let meanX = octaves.reduce(0, +) / count
        let meanY = bandDb.reduce(0, +) / count
        var covariance = 0.0
        var variance = 0.0
        for (x, y) in zip(octaves, bandDb) {
            covariance += (x - meanX) * (y - meanY)
            variance += (x - meanX) * (x - meanX)
        }
        return covariance / variance
    }
}
