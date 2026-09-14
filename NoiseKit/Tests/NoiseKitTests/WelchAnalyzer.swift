import Accelerate
import NoiseKit

// Welch periodogram: Hann-windowed segments, averaged power per bin
enum WelchAnalyzer {
    static let log2SegmentLength: vDSP_Length = 13
    static let segmentLength = 1 << 13

    static func averagedPowerSpectrum(samples: inout some IteratorProtocol<Float>, segmentCount: Int) -> [Float]? {
        let n = segmentLength
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        guard let setup = vDSP_create_fftsetup(log2SegmentLength, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var power = [Float](repeating: 0, count: n / 2)
        for _ in 0..<segmentCount {
            var real = (0..<n).map { _ in samples.next() ?? 0 }
            vDSP_vmul(real, 1, window, 1, &real, 1, vDSP_Length(n))
            var imag = [Float](repeating: 0, count: n)

            real.withUnsafeMutableBufferPointer { realPtr in
                imag.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, log2SegmentLength, FFTDirection(FFT_FORWARD))
                }
            }
            for k in 0..<(n / 2) {
                power[k] += real[k] * real[k] + imag[k] * imag[k]
            }
        }
        return power
    }

    static func bandPower(_ spectrum: [Float], bins: Range<Int>) -> Double {
        Double(spectrum[bins].reduce(0, +)) / Double(bins.count)
    }
}

struct GeneratorSampleIterator: IteratorProtocol {
    var generator: any NoiseGenerator

    mutating func next() -> Float? {
        generator.nextSample()
    }
}
