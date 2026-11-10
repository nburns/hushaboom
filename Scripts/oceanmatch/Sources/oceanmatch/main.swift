import Foundation
import NoiseKit

// Renders the ocean generator to a mono 32-bit float WAV so Scripts/ocean_match.py
// can score it against the reference measurements.

struct UsageError: Error, CustomStringConvertible {
    let description: String
}

struct Options {
    var seconds = 300.0
    var sampleRate = 44_100.0
    var seed: UInt64 = 20_261_109
    var output = "ocean.wav"
    var wavePeriod: Float = 0.5
    var waveHeight: Float = 0.5
    var waveVariation: Float = 0.5
    var surge: Float = 0.5
    var body: Float = 0.5
    var wash: Float = 0.5
    var spray: Float = 0.5
    // Raw overrides applied on top of the macros, for sweeping the tuning
    var layerSpread: Float?
    var churnDepth: Float?
    var crashBrightness: Float?
}

func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let flag = arguments[index]
        index += 1
        guard flag.hasPrefix("--") else {
            throw UsageError(description: "unexpected argument \(flag)")
        }
        guard index < arguments.count else {
            throw UsageError(description: "\(flag) needs a value")
        }
        let raw = arguments[index]
        index += 1

        func number() throws -> Double {
            guard let value = Double(raw) else {
                throw UsageError(description: "\(flag) needs a number, got \(raw)")
            }
            return value
        }
        func unit() throws -> Float {
            let value = try number()
            guard (0...1).contains(value) else {
                throw UsageError(description: "\(flag) must be 0...1, got \(raw)")
            }
            return Float(value)
        }

        switch flag {
        case "--seconds": options.seconds = try number()
        case "--rate": options.sampleRate = try number()
        case "--seed":
            guard let value = UInt64(raw) else {
                throw UsageError(description: "--seed needs an unsigned integer, got \(raw)")
            }
            options.seed = value
        case "--out": options.output = raw
        case "--period": options.wavePeriod = try unit()
        case "--height": options.waveHeight = try unit()
        case "--variation": options.waveVariation = try unit()
        case "--surge": options.surge = try unit()
        case "--body": options.body = try unit()
        case "--wash": options.wash = try unit()
        case "--spray": options.spray = try unit()
        case "--spread": options.layerSpread = try unit()
        case "--churn": options.churnDepth = try unit()
        case "--brightness":
            let value = try number()
            guard (-1.0...1.0).contains(value) else {
                throw UsageError(description: "--brightness must be -1...1, got \(raw)")
            }
            options.crashBrightness = Float(value)
        default: throw UsageError(description: "unknown flag \(flag)")
        }
    }
    guard options.seconds > 0 else {
        throw UsageError(description: "--seconds must be positive")
    }
    guard options.sampleRate >= 8_000 else {
        throw UsageError(description: "--rate must be at least 8000")
    }
    return options
}

func monoFloatWAV(_ samples: [Float], sampleRate: Double) -> Data {
    func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    func u16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    let payload = UInt32(samples.count * MemoryLayout<Float>.size)
    var data = Data()
    data.append(contentsOf: Array("RIFF".utf8))
    data.append(u32(36 + payload))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    data.append(u32(16))
    data.append(u16(3))                                   // IEEE float
    data.append(u16(1))                                   // mono, as NoisePlayer renders
    data.append(u32(UInt32(sampleRate)))
    data.append(u32(UInt32(sampleRate) * 4))
    data.append(u16(4))
    data.append(u16(32))
    data.append(contentsOf: Array("data".utf8))
    data.append(u32(payload))
    samples.withUnsafeBufferPointer { data.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
    return data
}

do {
    let options = try parse(Array(CommandLine.arguments.dropFirst()))
    var parameters = OceanParameters(
        wavePeriod: options.wavePeriod,
        waveHeight: options.waveHeight,
        waveVariation: options.waveVariation,
        surge: options.surge,
        body: options.body,
        wash: options.wash,
        spray: options.spray
    )
    if let value = options.layerSpread { parameters.layerSpread = value }
    if let value = options.churnDepth { parameters.churnDepth = value }
    if let value = options.crashBrightness { parameters.crashBrightness = value }
    var generator = OceanNoiseGenerator(
        seed: options.seed,
        sampleRate: options.sampleRate,
        parameters: parameters
    )
    let count = Int(options.seconds * options.sampleRate)
    var samples = [Float](repeating: 0, count: count)
    samples.withUnsafeMutableBufferPointer { generator.render(into: $0) }

    try monoFloatWAV(samples, sampleRate: options.sampleRate)
        .write(to: URL(fileURLWithPath: options.output))

    let peak = samples.lazy.map(abs).max() ?? 0
    let rms = (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(count)).squareRoot()
    FileHandle.standardError.write(
        Data("rendered \(options.seconds)s to \(options.output) (peak \(peak), rms \(rms))\n".utf8)
    )
} catch let error as UsageError {
    FileHandle.standardError.write(Data("oceanmatch: \(error.description)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("oceanmatch: \(error)\n".utf8))
    exit(1)
}
