@testable import NoiseKit

/// Coarsest useful envelope measurement: per-second RMS over a long render,
/// reduced to how far the sound swells between its quietest and loudest
/// second. Shared by every generator whose point is that it modulates.
func chunkRMSSwing(_ generator: inout some NoiseGenerator, seconds: Int) -> (quietest: Float, loudest: Float) {
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
