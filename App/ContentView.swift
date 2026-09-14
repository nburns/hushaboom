import NoiseKit
import SwiftUI

struct ContentView: View {
    private enum TimerSheet: String, Identifiable {
        case custom, until
        var id: String { rawValue }
    }

    @StateObject private var model = PlayerModel()
    @State private var timerSheet: TimerSheet?
    #if os(iOS)
    @State private var showingSettings = false
    #endif

    var body: some View {
        VStack(spacing: 28) {
            ScrollView {
                VStack(spacing: 20) {
                    ForEach(NoiseType.allCases) { type in
                        soundRow(type)
                        if isExpanded(type) {
                            VStack(spacing: 10) {
                                ForEach(subSettings(for: type), id: \.label) { setting in
                                    subSlider(setting.label, value: setting.value)
                                }
                            }
                            .padding(.leading, 28)
                            .transition(.opacity)
                        }
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .animation(.easeInOut(duration: 0.25), value: model.selectedType)
                .animation(.easeInOut(duration: 0.25), value: expansionFingerprint)
            }
            .scrollOnlyWhenNeeded()
            .mask(
                VStack(spacing: 0) {
                    Rectangle().fill(Color.black)
                    LinearGradient(
                        gradient: Gradient(colors: [.black, .clear]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 28)
                }
            )

            ZStack {
                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 56))
                        .foregroundColor(.accentColor)
                        .frame(width: 84, height: 84)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("playPauseButton")

                sleepTimerMenu
                    .offset(x: -88)

                #if os(iOS)
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settingsButton")
                .offset(x: 88)
                .sheet(isPresented: $showingSettings) {
                    SettingsView(model: model)
                }
                #endif
            }

            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                Slider(value: $model.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
            }
            .foregroundColor(.secondary)

            if let message = model.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: 480, maxHeight: 860)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 560)
        #endif
    }

    private var sleepTimerMenu: some View {
        Menu {
            if model.sleepTimerEnd != nil {
                Button("Cancel Timer") { model.cancelSleepTimer() }
                Divider()
            }
            Button("15 minutes") { model.setSleepTimer(minutes: 15) }
            Button("30 minutes") { model.setSleepTimer(minutes: 30) }
            Button("1 hour") { model.setSleepTimer(minutes: 60) }
            Button("Custom…") { timerSheet = .custom }
            Button("Until…") { timerSheet = .until }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: model.sleepTimerEnd == nil ? "moon.zzz" : "moon.zzz.fill")
                    .font(.title3)
                if let end = model.sleepTimerEnd {
                    Text(end, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .fixedSize()
                }
            }
            .foregroundColor(model.sleepTimerEnd == nil ? .secondary : .accentColor)
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier("sleepTimerMenu")
        .menuStyle(.borderlessButton)
        .fixedSize()
        .sheet(item: $timerSheet) { sheet in
            switch sheet {
            case .custom: CustomSleepTimerView(model: model)
            case .until: UntilSleepTimerView(model: model)
            }
        }
    }

    private func soundRow(_ type: NoiseType) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 14) {
                Circle()
                    .fill(tint(for: type))
                    .frame(width: 14, height: 14)
                Text(type.displayName)
                    .frame(width: 60, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectedType = model.selectedType == type ? nil : type
            }
            Slider(
                value: model.levelBinding(for: type),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing { model.selectedType = type }
                }
            )
            .tint(tint(for: type))
        }
    }

    private func subSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .leading)
            Slider(value: value, in: 0...1)
                .tint(Color.secondary.opacity(0.5))
        }
    }

    private func isExpanded(_ type: NoiseType) -> Bool {
        model.selectedType == type
            && (model.levels[type] ?? 0) > 0
            && !subSettings(for: type).isEmpty
    }

    // Levels feed into expansion via the > 0 check; animating on this keeps
    // collapse smooth when a selected row is dragged to zero
    private var expansionFingerprint: [Bool] {
        NoiseType.allCases.map { isExpanded($0) }
    }

    private func subSettings(for type: NoiseType) -> [(label: String, value: Binding<Double>)] {
        switch type {
        case .white, .pink, .brown:
            return []
        case .ocean:
            return [
                ("Period", $model.oceanWavePeriod),
                ("Height", $model.oceanWaveHeight),
                ("Tone", $model.oceanTone),
            ]
        case .wind:
            return [
                ("Gusts", $model.windGustiness),
                ("Tone", $model.windTone),
            ]
        case .rain:
            return [
                ("Intensity", $model.rainIntensity),
                ("Rate", $model.rainRate),
                ("Drop size", $model.rainDropSize),
                ("Surface", $model.rainSurface),
            ]
        case .trees:
            return [
                ("Breeze", $model.treesBreeze),
                ("Density", $model.treesDensity),
                ("Leaf size", $model.treesLeafSize),
            ]
        }
    }

    private func tint(for type: NoiseType) -> Color {
        switch type {
        case .white: return .gray
        case .pink: return .pink
        case .brown: return .brown
        case .ocean: return .teal
        case .wind: return Color(white: 0.75)
        case .rain: return .blue
        case .trees: return .green
        }
    }
}

struct CustomSleepTimerView: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var minutesText = ""

    private var minutes: Int? {
        guard let value = Int(minutesText), value > 0 else { return nil }
        return value
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("Minutes", text: $minutesText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            .navigationTitle("Sleep Timer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        if let minutes {
                            model.setSleepTimer(minutes: minutes)
                            dismiss()
                        }
                    }
                    .disabled(minutes == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 280, height: 150)
        #endif
    }
}

struct UntilSleepTimerView: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var time: Date

    init(model: PlayerModel) {
        self.model = model
        _time = State(initialValue: model.preferredSleepUntil)
    }

    var body: some View {
        NavigationView {
            Form {
                DatePicker("Stop at", selection: $time, displayedComponents: .hourAndMinute)
            }
            .navigationTitle("Sleep Timer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        // The picker gives hour/minute on an arbitrary day;
                        // the timer targets the next occurrence of that time
                        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
                        if let target = Calendar.current.nextDate(
                            after: Date(),
                            matching: components,
                            matchingPolicy: .nextTime
                        ) {
                            model.rememberSleepUntil(time)
                            model.setSleepTimer(until: target)
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 280, height: 150)
        #endif
    }
}

#if os(iOS)
struct SettingsView: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("Play in background", isOn: $model.mixWithOtherAudio)
                } footer: {
                    Text("Keeps playing mixed with audio from other apps instead of pausing them. While mixing, lock screen playback controls are unavailable.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif

private extension View {
    // scrollBounceBehavior needs iOS 16.4/macOS 13.3; older OSes keep the
    // always-bouncing ScrollView
    @ViewBuilder func scrollOnlyWhenNeeded() -> some View {
        if #available(iOS 16.4, macOS 13.3, *) {
            scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }
}
