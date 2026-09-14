import AVFoundation
import os

/// Not thread-safe: call from the main thread. Recovery callbacks arrive
/// on the main queue.
public final class NoisePlayer {
    private var engine = AVAudioEngine()
    private let renderState: RenderState
    private var observers: [NSObjectProtocol] = []
    private var storedVolume: Float = 0.7

    public private(set) var isPlaying = false

    /// Called (on the main queue) when playback stops or resumes because of
    /// a system event - route change, interruption, media daemon reset -
    /// rather than a start()/stop() call. `false` means recovery failed and
    /// playback is off until start() is called again.
    public var onPlaybackStateChange: ((Bool) -> Void)?

    public var volume: Float {
        get { storedVolume }
        set {
            storedVolume = max(0, min(1, newValue))
            engine.mainMixerNode.outputVolume = storedVolume
        }
    }

    public init(seed: UInt64? = nil) {
        let probe = AVAudioEngine()
        let outputFormat = probe.outputNode.inputFormat(forBus: 0)
        let sampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 44_100
        renderState = RenderState(seed: seed, sampleRate: sampleRate)
        engine = probe
        configureEngine()
        observeSystemEvents()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    public func level(for color: NoiseType) -> Float {
        renderState.level(for: color)
    }

    /// Levels are perceptual (0...1); the player squares them into gain so
    /// the low end of a slider stays usable.
    public func setLevel(_ level: Float, for color: NoiseType) {
        renderState.setLevel(max(0, min(1, level)), for: color)
    }

    public var oceanParameters: OceanParameters {
        get { renderState.withBank { $0.ocean.parameters } }
        set { renderState.withBank { $0.ocean.parameters = newValue } }
    }

    public var windParameters: WindParameters {
        get { renderState.withBank { $0.wind.parameters } }
        set { renderState.withBank { $0.wind.parameters = newValue } }
    }

    public var rainParameters: RainParameters {
        get { renderState.withBank { $0.rain.parameters } }
        set { renderState.withBank { $0.rain.parameters = newValue } }
    }

    public var treesParameters: TreesParameters {
        get { renderState.withBank { $0.trees.parameters } }
        set { renderState.withBank { $0.trees.parameters = newValue } }
    }

    /// iOS: when true, playback mixes with other apps' audio (music,
    /// podcasts) instead of interrupting it. While mixing, iOS treats the
    /// app as secondary audio, so lock screen and Control Center transport
    /// controls are not shown. macOS always mixes; the flag has no effect.
    public private(set) var mixesWithOthers = false

    /// Applies immediately if playing; throws if the audio session rejects
    /// the change (playback continues with the previous behavior).
    public func setMixesWithOthers(_ enabled: Bool) throws {
        let previous = mixesWithOthers
        mixesWithOthers = enabled
        #if os(iOS)
        if isPlaying && enabled != previous {
            do {
                try applyAudioSession()
            } catch {
                mixesWithOthers = previous
                throw error
            }
        }
        #endif
    }

    public func start() throws {
        try startEngine()
        isPlaying = true
    }

    public func stop() {
        engine.pause()
        isPlaying = false
    }

    #if os(iOS)
    private func applyAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: mixesWithOthers ? [.mixWithOthers] : [])
        try session.setActive(true)
    }
    #endif

    private func startEngine() throws {
        #if os(iOS)
        try applyAudioSession()
        #endif
        try engine.start()
    }

    private func configureEngine() {
        let state = renderState
        // The graph's mixer resamples if the hardware rate differs from the
        // render state's fixed rate, so one rate for the generators is fine
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: renderState.sampleRate, channels: 1) else {
            fatalError("Could not create mono float format at \(renderState.sampleRate) Hz")
        }
        let sourceNode = AVAudioSourceNode(format: monoFormat) { _, _, frameCount, audioBufferList in
            state.render(frameCount: frameCount, audioBufferList: audioBufferList)
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: monoFormat)
        engine.mainMixerNode.outputVolume = storedVolume
    }

    // Overnight resilience: the engine stops on output route changes
    // (Bluetooth headphones dying), iOS interruptions (calls, alarms), and
    // media daemon resets. Restart it whenever the user still expects sound.
    private func observeSystemEvents() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.recoverIfNeeded()
        })

        #if os(iOS)
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            if type == .ended {
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                    self.recoverIfNeeded()
                }
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Apple requires discarding the engine after a daemon reset
            self.observers.forEach { NotificationCenter.default.removeObserver($0) }
            self.observers.removeAll()
            self.engine = AVAudioEngine()
            self.configureEngine()
            self.observeSystemEvents()
            self.recoverIfNeeded()
        })
        #endif
    }

    private func recoverIfNeeded(attempt: Int = 0) {
        guard isPlaying else { return }
        do {
            try startEngine()
            onPlaybackStateChange?(true)
        } catch {
            // Right after a route change the new device may not be ready;
            // back off briefly before giving up
            if attempt < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(attempt + 1)) { [weak self] in
                    self?.recoverIfNeeded(attempt: attempt + 1)
                }
            } else {
                isPlaying = false
                onPlaybackStateChange?(false)
            }
        }
    }
}

// Owned jointly by the control thread (level setters) and the audio render
// thread; every access goes through an unfair lock. The critical section is
// a few arithmetic ops per sample, short enough not to starve the render
// deadline in practice.
private final class RenderState: @unchecked Sendable {
    private static let colors = NoiseType.allCases

    let sampleRate: Double

    private let lock: UnsafeMutablePointer<os_unfair_lock_s>
    private var bank: NoiseBank
    private var levels: [Float]
    private var targetGains: [Float]
    private var currentGains: [Float]
    private let gainSmoothing: Float

    init(seed: UInt64?, sampleRate: Double) {
        self.sampleRate = sampleRate
        lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
        bank = NoiseBank(seed: seed, sampleRate: sampleRate)
        levels = [Float](repeating: 0, count: Self.colors.count)
        targetGains = levels
        currentGains = levels
        // One-pole smoothing with ~30 ms time constant to avoid zipper noise
        gainSmoothing = 1 - exp(-1 / Float(0.03 * sampleRate))
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func level(for color: NoiseType) -> Float {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return levels[Self.colors.firstIndex(of: color)!]
    }

    func setLevel(_ level: Float, for color: NoiseType) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let index = Self.colors.firstIndex(of: color)!
        levels[index] = level
        targetGains[index] = level * level
    }

    func withBank<T>(_ body: (inout NoiseBank) -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body(&bank)
    }

    func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let first = buffers.first,
              let samples = first.mData?.assumingMemoryBound(to: Float.self) else {
            return kAudioUnitErr_InvalidParameter
        }

        os_unfair_lock_lock(lock)
        for frame in 0..<Int(frameCount) {
            var mix: Float = 0
            for index in 0..<Self.colors.count {
                currentGains[index] += (targetGains[index] - currentGains[index]) * gainSmoothing
                if currentGains[index] > 1e-5 {
                    mix += bank.nextSample(index) * currentGains[index]
                }
            }
            // Colors sum uncorrelated, so peaks rarely exceed full scale
            // even with every slider up; clamp the stragglers instead of
            // letting the DAC wrap
            samples[frame] = max(-1, min(1, mix))
        }
        os_unfair_lock_unlock(lock)

        for extra in buffers.dropFirst() {
            if let dst = extra.mData?.assumingMemoryBound(to: Float.self) {
                dst.update(from: samples, count: Int(frameCount))
            }
        }
        return noErr
    }
}

private struct NoiseBank {
    var white: WhiteNoiseGenerator
    var pink: PinkNoiseGenerator
    var brown: BrownNoiseGenerator
    var ocean: OceanNoiseGenerator
    var wind: WindNoiseGenerator
    var rain: RainNoiseGenerator
    var trees: TreesNoiseGenerator

    init(seed: UInt64?, sampleRate: Double) {
        white = WhiteNoiseGenerator(seed: seed)
        pink = PinkNoiseGenerator(seed: seed.map { $0 &+ 1 })
        brown = BrownNoiseGenerator(seed: seed.map { $0 &+ 2 })
        ocean = OceanNoiseGenerator(seed: seed.map { $0 &+ 3 }, sampleRate: sampleRate)
        wind = WindNoiseGenerator(seed: seed.map { $0 &+ 4 }, sampleRate: sampleRate)
        rain = RainNoiseGenerator(seed: seed.map { $0 &+ 5 }, sampleRate: sampleRate)
        trees = TreesNoiseGenerator(seed: seed.map { $0 &+ 6 }, sampleRate: sampleRate)
    }

    // Index follows NoiseType.allCases order
    mutating func nextSample(_ index: Int) -> Float {
        switch index {
        case 0: return white.nextSample()
        case 1: return pink.nextSample()
        case 2: return brown.nextSample()
        case 3: return ocean.nextSample()
        case 4: return wind.nextSample()
        case 5: return rain.nextSample()
        default: return trees.nextSample()
        }
    }
}
