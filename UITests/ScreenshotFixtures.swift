import Foundation

enum ScreenshotFixtures {
    /// A mix that looks deliberate rather than default: a few sounds up, the
    /// rest at zero, so the sliders read as a mixer. Ocean has to be above
    /// zero or its sub-settings refuse to expand.
    static let levels: [String: Double] = [
        "level.white": 0.45,
        "level.pink": 0,
        "level.brown": 0.25,
        "level.ocean": 0.65,
        "level.wind": 0,
        "level.rain": 0.35,
        "level.trees": 0,
        "volume": 0.7,
        "ocean.wavePeriod": 0.55,
        "ocean.waveHeight": 0.7,
        "ocean.tone": 0.4,
        "rain.intensity": 0.5,
        "rain.surface": 0.5,
        "rain.rate": 0.5,
        "rain.dropSize": 0.5,
    ]

    /// 22:30, so the "Until…" picker does not default to the wall clock.
    static let integers: [String: Int] = ["sleepTimer.untilMinutes": 1350]

    static let flags: [String: Bool] = ["mixWithOtherAudio": false]

    /// The argument domain parses a value as a property list only when it
    /// looks like one. A bare `0.65` arrives as a string, `as? Double` returns
    /// nil, and every slider silently falls back to its default - so the
    /// fixtures have to be written as plist fragments.
    static var launchArguments: [String] {
        var arguments: [String] = []
        for (key, value) in levels.sorted(by: { $0.key < $1.key }) {
            arguments += ["-\(key)", "<real>\(value)</real>"]
        }
        for (key, value) in integers.sorted(by: { $0.key < $1.key }) {
            arguments += ["-\(key)", "<integer>\(value)</integer>"]
        }
        for (key, value) in flags.sorted(by: { $0.key < $1.key }) {
            arguments += ["-\(key)", value ? "<true/>" : "<false/>"]
        }
        return arguments
    }

}
