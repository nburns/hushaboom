import Foundation
import MediaPlayer
import NoiseKit
import SwiftUI

@MainActor
final class PlayerModel: ObservableObject {
    private enum Keys {
        static func level(_ type: NoiseType) -> String { "level.\(type.rawValue)" }
        static let volume = "volume"
        static let oceanWavePeriod = "ocean.wavePeriod"
        static let oceanWaveHeight = "ocean.waveHeight"
        static let oceanTone = "ocean.tone"
        static let windGustiness = "wind.gustiness"
        static let windTone = "wind.tone"
        static let rainIntensity = "rain.intensity"
        static let rainSurface = "rain.surface"
        static let rainRate = "rain.rate"
        static let rainDropSize = "rain.dropSize"
        static let treesBreeze = "trees.breeze"
        static let treesDensity = "trees.density"
        static let treesLeafSize = "trees.leafSize"
        static let mixWithOtherAudio = "mixWithOtherAudio"
        static let sleepUntilMinutes = "sleepTimer.untilMinutes"
    }

    /// The row whose sub-sliders are expanded; selecting a row collapses
    /// any other.
    @Published var selectedType: NoiseType?

    @Published var levels: [NoiseType: Double] {
        didSet {
            for color in NoiseType.allCases where levels[color] != oldValue[color] {
                player.setLevel(Float(levels[color] ?? 0), for: color)
                store.set(levels[color] ?? 0, forKey: Keys.level(color))
            }
            updateNowPlayingInfo()
        }
    }

    @Published var volume: Double {
        didSet {
            player.volume = Float(volume)
            store.set(volume, forKey: Keys.volume)
        }
    }

    @Published var oceanWavePeriod: Double {
        didSet {
            pushOceanParameters()
            store.set(oceanWavePeriod, forKey: Keys.oceanWavePeriod)
        }
    }

    @Published var oceanWaveHeight: Double {
        didSet {
            pushOceanParameters()
            store.set(oceanWaveHeight, forKey: Keys.oceanWaveHeight)
        }
    }

    @Published var oceanTone: Double {
        didSet {
            pushOceanParameters()
            store.set(oceanTone, forKey: Keys.oceanTone)
        }
    }

    @Published var windGustiness: Double {
        didSet {
            player.windParameters = WindParameters(gustiness: Float(windGustiness), tone: Float(windTone))
            store.set(windGustiness, forKey: Keys.windGustiness)
        }
    }

    @Published var windTone: Double {
        didSet {
            player.windParameters = WindParameters(gustiness: Float(windGustiness), tone: Float(windTone))
            store.set(windTone, forKey: Keys.windTone)
        }
    }

    @Published var rainIntensity: Double {
        didSet {
            pushRainParameters()
            store.set(rainIntensity, forKey: Keys.rainIntensity)
        }
    }

    @Published var rainSurface: Double {
        didSet {
            pushRainParameters()
            store.set(rainSurface, forKey: Keys.rainSurface)
        }
    }

    @Published var rainRate: Double {
        didSet {
            pushRainParameters()
            store.set(rainRate, forKey: Keys.rainRate)
        }
    }

    @Published var rainDropSize: Double {
        didSet {
            pushRainParameters()
            store.set(rainDropSize, forKey: Keys.rainDropSize)
        }
    }

    @Published var treesBreeze: Double {
        didSet {
            pushTreesParameters()
            store.set(treesBreeze, forKey: Keys.treesBreeze)
        }
    }

    @Published var treesDensity: Double {
        didSet {
            pushTreesParameters()
            store.set(treesDensity, forKey: Keys.treesDensity)
        }
    }

    @Published var treesLeafSize: Double {
        didSet {
            pushTreesParameters()
            store.set(treesLeafSize, forKey: Keys.treesLeafSize)
        }
    }

    @Published var mixWithOtherAudio: Bool {
        didSet {
            do {
                try player.setMixesWithOthers(mixWithOtherAudio)
                store.set(mixWithOtherAudio, forKey: Keys.mixWithOtherAudio)
            } catch {
                mixWithOtherAudio = oldValue
                errorMessage = "Could not change audio mixing: \(error.localizedDescription)"
            }
        }
    }

    @Published private(set) var isPlaying = false {
        didSet { updateNowPlayingInfo() }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var sleepTimerEnd: Date?
    private var sleepTimerTask: Task<Void, Never>?

    private let player = NoisePlayer()
    private let store = UserDefaults.standard
    private var commandTargets: [Any] = []
    private var lastNowPlaying: (title: String, playing: Bool)?

    init() {
        let store = UserDefaults.standard
        func restored(_ key: String, default defaultValue: Double) -> Double {
            store.object(forKey: key) as? Double ?? defaultValue
        }
        levels = Dictionary(uniqueKeysWithValues: NoiseType.allCases.map { color in
            (color, restored(Keys.level(color), default: color == .white ? 0.7 : 0))
        })
        volume = restored(Keys.volume, default: 0.7)
        oceanWavePeriod = restored(Keys.oceanWavePeriod, default: 0.5)
        oceanWaveHeight = restored(Keys.oceanWaveHeight, default: 0.5)
        oceanTone = restored(Keys.oceanTone, default: 0.5)
        windGustiness = restored(Keys.windGustiness, default: 0.5)
        windTone = restored(Keys.windTone, default: 0.5)
        rainIntensity = restored(Keys.rainIntensity, default: 0.5)
        rainSurface = restored(Keys.rainSurface, default: 0.5)
        rainRate = restored(Keys.rainRate, default: 0.5)
        rainDropSize = restored(Keys.rainDropSize, default: 0.5)
        treesBreeze = restored(Keys.treesBreeze, default: 0.5)
        treesDensity = restored(Keys.treesDensity, default: 0.5)
        treesLeafSize = restored(Keys.treesLeafSize, default: 0.5)
        mixWithOtherAudio = store.object(forKey: Keys.mixWithOtherAudio) as? Bool ?? false

        // Cannot throw here: the session is only touched while playing
        try? player.setMixesWithOthers(mixWithOtherAudio)
        player.volume = Float(volume)
        for (color, level) in levels {
            player.setLevel(Float(level), for: color)
        }
        pushOceanParameters()
        player.windParameters = WindParameters(gustiness: Float(windGustiness), tone: Float(windTone))
        pushRainParameters()
        pushTreesParameters()

        player.onPlaybackStateChange = { [weak self] playing in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = playing
                self.errorMessage = playing ? nil : "Audio stopped and could not be resumed - press play to restart."
            }
        }

        configureRemoteCommands()
        updateNowPlayingInfo()
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        // Remote command handlers can arrive off the main thread; hop and
        // report success optimistically - start failures surface in the UI
        commandTargets.append(center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.isPlaying else { return }
                self.togglePlayback()
            }
            return .success
        })
        commandTargets.append(center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isPlaying else { return }
                self.togglePlayback()
            }
            return .success
        })
        commandTargets.append(center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.togglePlayback() }
            return .success
        })
        center.stopCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    private var activeMixDescription: String {
        let active = NoiseType.allCases
            .filter { (levels[$0] ?? 0) > 0 }
            .map(\.displayName)
        return active.isEmpty ? "Noise" : active.joined(separator: " + ")
    }

    private func updateNowPlayingInfo() {
        // The info center is an XPC call; skip it when nothing it shows has
        // changed (e.g. every tick of a level-slider drag)
        let state = (title: activeMixDescription, playing: isPlaying)
        if let last = lastNowPlaying, last == state {
            return
        }
        lastNowPlaying = state

        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: state.title,
            MPMediaItemPropertyArtist: "Hushaboom",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: state.playing ? 1.0 : 0.0,
        ]
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = state.playing ? .playing : .paused
        #endif
    }

    private func pushRainParameters() {
        player.rainParameters = RainParameters(
            intensity: Float(rainIntensity),
            surface: Float(rainSurface),
            rate: Float(rainRate),
            dropSize: Float(rainDropSize)
        )
    }

    private func pushTreesParameters() {
        player.treesParameters = TreesParameters(
            breeze: Float(treesBreeze),
            density: Float(treesDensity),
            leafSize: Float(treesLeafSize)
        )
    }

    private func pushOceanParameters() {
        player.oceanParameters = OceanParameters(
            wavePeriod: Float(oceanWavePeriod),
            waveHeight: Float(oceanWaveHeight),
            tone: Float(oceanTone)
        )
    }

    func levelBinding(for color: NoiseType) -> Binding<Double> {
        Binding(
            get: { [weak self] in self?.levels[color] ?? 0 },
            set: { [weak self] in self?.levels[color] = $0 }
        )
    }

    func togglePlayback() {
        if isPlaying {
            cancelSleepTimer()
            player.stop()
            isPlaying = false
        } else {
            do {
                try player.start()
                isPlaying = true
                errorMessage = nil
            } catch {
                errorMessage = "Could not start audio: \(error.localizedDescription)"
            }
        }
    }

    func setSleepTimer(minutes: Int) {
        setSleepTimer(until: Date().addingTimeInterval(TimeInterval(minutes) * 60))
    }

    func setSleepTimer(until end: Date) {
        sleepTimerTask?.cancel()
        sleepTimerEnd = end
        let seconds = max(0, end.timeIntervalSinceNow)
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.sleepTimerEnd == end else { return }
            self.sleepTimerEnd = nil
            self.sleepTimerTask = nil
            if self.isPlaying {
                self.togglePlayback()
            }
        }
    }

    /// Default for the "Until" picker: the last time the user chose,
    /// projected onto today (falls back to now before any choice is made).
    var preferredSleepUntil: Date {
        guard let minutes = store.object(forKey: Keys.sleepUntilMinutes) as? Int,
              let date = Calendar.current.date(
                bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()
              ) else {
            return Date()
        }
        return date
    }

    func rememberSleepUntil(_ date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        store.set((components.hour ?? 0) * 60 + (components.minute ?? 0), forKey: Keys.sleepUntilMinutes)
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEnd = nil
    }
}
