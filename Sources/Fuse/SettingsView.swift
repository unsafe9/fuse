import SwiftUI
import AppKit

/// The SwiftUI Settings UI (feature 5), hosted in `SettingsWindowController` via
/// `NSHostingController`.
///
/// Binds to `SettingsStore.shared` (passed as an `@ObservedObject`) and exposes every
/// persisted setting: the unified preset list, fuse color,
/// thickness (1–20 pt), edge position, target display (Main Display by default,
/// All Displays, or a specific screen), overlay master toggle, show-remaining-in-menubar toggle,
/// notification enabled + body template + sound toggle, prevent-system-sleep toggle,
/// and keep-awake-with-lid-closed toggle.
/// A settings tab, used to open the window directly to a given pane.
enum SettingsTab: Hashable {
    case general, fuse, notifications, power
}

/// Drives which tab the Settings window shows, so callers (e.g. the notification
/// fix-it flow) can deep-link to a specific pane.
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selectedTab: SettingsTab = .general
    private init() {}
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var nav = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $nav.selectedTab) {
            GeneralTab(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            FuseTab(store: store)
                .tabItem { Label("Fuse", systemImage: "flame") }
                .tag(SettingsTab.fuse)
            NotificationsTab(store: store)
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsTab.notifications)
            PowerTab(store: store)
                .tabItem { Label("Power", systemImage: "bolt") }
                .tag(SettingsTab.power)
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
                PresetListEditor(presets: $store.presets)
            } header: {
                Text("Presets")
            }

            Section {
                Toggle("Show remaining time in menu bar", isOn: $store.showRemainingInMenuBar)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Preset list editor

/// A compact native list editor for the deduplicated `[String]` preset list whose order
/// is user-controlled (it drives the menu order). Each row shows a human-readable label
/// (derived by parsing the expression) with up/down reorder buttons and a remove button;
/// rows can also be drag-reordered. The footer is a text field that validates a new time
/// expression through `Preset.parse`; valid, non-duplicate values append to the end,
/// invalid ones show an inline error and keep focus.
private struct PresetListEditor: View {
    @Binding var presets: [String]

    @State private var newExpression: String = ""
    @State private var errorMessage: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if presets.isEmpty {
                Text("No presets.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                List {
                    ForEach(Array(presets.enumerated()), id: \.element) { index, value in
                        HStack {
                            Text(rowLabel(value))
                            Spacer()
                            Button {
                                move(from: index, to: index - 1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                            Button {
                                move(from: index, to: index + 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == presets.count - 1)
                            Button {
                                presets.removeAll { $0 == value }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onMove { presets.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .frame(height: CGFloat(presets.count) * 28 + 8)
                .scrollDisabled(true)
            }

            Divider()

            HStack {
                TextField("5m, 1h30m, 90, :15, :00", text: $newExpression)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { add() }
                Spacer()
                Button("Add") { add() }
                    .disabled(newExpression.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    /// "5 min" / "1 h 30 min" for durations, ":15" / "top of hour" for marks. Unparsable
    /// (shouldn't occur for stored presets) falls back to the raw expression.
    private func rowLabel(_ expression: String) -> String {
        switch Preset.parse(expression) {
        case .duration(let seconds): return PresetLabel.duration(seconds: seconds)
        case .mark(let minute): return PresetLabel.markSettings(minute: minute)
        case nil: return expression
        }
    }

    private func move(from: Int, to: Int) {
        guard presets.indices.contains(from), presets.indices.contains(to) else { return }
        presets.swapAt(from, to)
    }

    private func add() {
        let trimmed = newExpression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard Preset.parse(trimmed) != nil else {
            errorMessage = "Invalid time. Try 5m, 1h30m, 90, :15, or :00."
            fieldFocused = true
            return
        }
        guard !presets.contains(trimmed) else {
            errorMessage = "That preset is already in the list."
            fieldFocused = true
            return
        }
        presets.append(trimmed)
        newExpression = ""
        errorMessage = ""
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

                Picker("Texture", selection: $store.fuseTexture) {
                    ForEach(FuseTexture.allCases, id: \.self) { texture in
                        Text(texture.displayName).tag(texture)
                    }
                }

                Picker("Burning tip", selection: $store.fuseTipEffect) {
                    ForEach(FuseTipEffect.allCases, id: \.self) { effect in
                        Text(effect.displayName).tag(effect)
                    }
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
                    Toggle("Keep Mac awake with lid closed",
                           isOn: $store.keepAwakeLidClosed)
                    Text("Disables lid-close sleep while a timer runs. No admin password needed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
