import SwiftUI
import AppKit

/// The SwiftUI Settings UI (feature 5), hosted in `SettingsWindowController` via
/// `NSHostingController`.
///
/// Binds to `SettingsStore.shared` (passed as an `@ObservedObject`) and exposes every
/// persisted setting: duration presets, deadline presets, preset mode, fuse color,
/// thickness (1–20 pt), edge position, target display (Main Display by default,
/// All Displays, or a specific screen), overlay master toggle, show-remaining-in-menubar toggle,
/// notification enabled + body template + sound toggle, prevent-system-sleep toggle,
/// and keep-awake-with-lid-closed toggle.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        TabView {
            GeneralTab(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            FuseTab(store: store)
                .tabItem { Label("Fuse", systemImage: "flame") }
            NotificationsTab(store: store)
                .tabItem { Label("Notifications", systemImage: "bell") }
            PowerTab(store: store)
                .tabItem { Label("Power", systemImage: "bolt") }
        }
        .frame(width: 480)
        .fixedSize()
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Preset mode", selection: $store.presetMode) {
                    ForEach(PresetMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if store.presetMode.showsDuration {
                Section {
                    PresetListEditor(
                        presets: $store.durationPresets,
                        label: { TimeFormat.presetLabel(minutes: $0) },
                        addPrompt: "Minutes"
                    )
                } header: {
                    Text("Duration Presets")
                }
            }

            if store.presetMode.showsDeadline {
                Section {
                    PresetListEditor(
                        presets: $store.deadlinePresets,
                        label: deadlinePresetLabel,
                        addPrompt: "Minute mark",
                        maxValue: 60
                    )
                } header: {
                    Text("Deadline Presets")
                }
            }

            Section {
                Toggle("Show remaining time in menu bar", isOn: $store.showRemainingInMenuBar)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// ":15" for a minute-of-hour mark; 60 (≡ 0) reads as "Top of hour (:00)".
    private func deadlinePresetLabel(_ mark: Int) -> String {
        if mark % 60 == 0 {
            return "Top of hour (:00)"
        }
        return ":\(String(format: "%02d", mark % 60))"
    }
}

// MARK: - Preset list editor

/// A compact native list editor for a sorted, deduplicated `[Int]` preset list.
/// Each row shows a human-readable `label`; a footer row adds a new positive value,
/// optionally capped at `maxValue`.
private struct PresetListEditor: View {
    @Binding var presets: [Int]
    let label: (Int) -> String
    let addPrompt: String
    var maxValue: Int? = nil

    @State private var newValue: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if presets.isEmpty {
                Text("No presets.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(presets, id: \.self) { value in
                    HStack {
                        Text(label(value))
                        Spacer()
                        Button {
                            presets.removeAll { $0 == value }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Divider()

            HStack {
                TextField(addPrompt, value: $newValue, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onSubmit { add() }
                Stepper(
                    "",
                    value: Binding(get: { newValue ?? 0 }, set: { newValue = $0 }),
                    in: 0...(maxValue ?? 10_000)
                )
                .labelsHidden()
                Spacer()
                Button("Add") { add() }
                    .disabled(!isAddable(newValue ?? 0))
            }
        }
    }

    private func isAddable(_ value: Int) -> Bool {
        value > 0 && value <= (maxValue ?? Int.max)
    }

    private func add() {
        guard let value = newValue, isAddable(value) else { return }
        guard !presets.contains(value) else { newValue = nil; return }
        presets = (presets + [value]).sorted()
        newValue = nil
    }
}

// MARK: - Fuse Tab

private struct FuseTab: View {
    @ObservedObject var store: SettingsStore

    /// Available screens at the time the tab was shown.
    @State private var screens: [(id: CGDirectDisplayID, name: String)] = []

    var body: some View {
        Form {
            Section {
                Toggle("Enable overlay", isOn: $store.overlayEnabled)
            }

            Section {
                ColorPicker("Fuse color", selection: fuseColorBinding)

                HStack {
                    Text("Thickness")
                    Slider(value: $store.fuseThickness,
                           in: SettingsStore.minThickness...SettingsStore.maxThickness,
                           step: 1)
                    Text("\(Int(store.fuseThickness)) pt")
                        .frame(width: 40, alignment: .trailing)
                        .monospacedDigit()
                }

                Picker("Position", selection: $store.fusePosition) {
                    ForEach(FusePosition.allCases, id: \.self) { pos in
                        Text(pos.displayName).tag(pos)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            }

            Section {
                Picker("Display", selection: $store.fuseDisplay) {
                    Text("Main Display").tag(FuseDisplay.main)
                    Text("All Displays").tag(FuseDisplay.all)
                    ForEach(screens, id: \.id) { screen in
                        Text(screen.name).tag(FuseDisplay.id(screen.id))
                    }
                }
            } header: {
                Text("Display")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            refreshScreens()
            // Show a live overlay preview while this tab is visible so appearance
            // changes are immediately visible even with no timer running.
            NotificationCenter.default.post(name: .fusePreviewBegan, object: nil)
        }
        .onDisappear {
            NotificationCenter.default.post(name: .fusePreviewEnded, object: nil)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in refreshScreens() }
    }

    private var fuseColorBinding: Binding<Color> {
        Binding(
            get: { Color(store.fuseColor) },
            set: { store.fuseColor = NSColor($0) }
        )
    }

    private func refreshScreens() {
        screens = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (id: id, name: screen.localizedName)
        }
    }
}

// MARK: - Notifications Tab

private struct NotificationsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Enable notifications", isOn: $store.notificationEnabled)
            }

            if store.notificationEnabled {
                Section {
                    TextField("Notification body", text: $store.notificationTemplate)
                    Toggle("Play sound", isOn: $store.notificationSound)
                } header: {
                    Text("Notification Options")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Power Tab

private struct PowerTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Prevent system idle sleep while timer runs", isOn: $store.preventSleep)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Keep Mac awake with lid closed (requires admin password)",
                           isOn: $store.keepAwakeLidClosed)
                    Text("Uses pmset disablesleep. Prompts for your password when a timer starts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
