import AppKit
import Combine
import CoreGraphics

/// Single source of truth for every persisted user setting (feature 5).
///
/// Each `@Published` property writes through to `UserDefaults` on `didSet` and is
/// loaded back in `init`. Observers may watch `objectWillChange` (SwiftUI) or the
/// store's individual property changes. The store is an `ObservableObject` so the
/// SwiftUI Settings UI binds to it directly.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    // MARK: Defaults keys

    private enum Key {
        static let presets = "presets"
        static let durationPresets = "durationPresets"
        static let deadlinePresets = "deadlinePresets"
        static let fuseColorHex = "fuseColorHex"
        static let fuseThickness = "fuseThickness"
        static let fuseTexture = "fuseTexture"
        static let fuseTipEffect = "fuseTipEffect"
        static let fusePosition = "fusePosition"
        static let fuseDisplay = "fuseDisplay"
        static let overlayEnabled = "overlayEnabled"
        static let showRemainingInMenuBar = "showRemainingInMenuBar"
        static let notificationEnabled = "notificationEnabled"
        static let notificationTemplate = "notificationTemplate"
        static let notificationSound = "notificationSound"
        static let preventSleep = "preventSleep"
        static let keepAwakeLidClosed = "keepAwakeLidClosed"
    }

    // MARK: Default values

    /// Fresh-install presets: durations first, then minute-of-hour marks. Each is a
    /// time expression (the same grammar as the custom panel and AppleScript).
    static let defaultPresets = ["1m", "3m", "5m", "10m", "15m", "20m", "30m", "45m", "60m", "90m", "120m", ":15", ":30", ":45", ":00"]
    /// Pure red, fully opaque.
    static let defaultColorHex = "FF1F1FFF"
    static let defaultThickness: Double = 4
    static let minThickness: Double = 1
    static let maxThickness: Double = 20
    /// Fresh-install fuse design: a braided rope with a licking flame tip.
    static let defaultTexture: FuseTexture = .rope
    static let defaultTipEffect: FuseTipEffect = .flame

    // MARK: Published settings (feature 5)

    /// Ordered list of preset time expressions (e.g. "5m", "1h30m", ":15", ":00").
    /// The order drives the status menu order. The user mixes durations and marks
    /// freely; there is no duration/deadline distinction in storage.
    @Published var presets: [String] {
        didSet { defaults.set(presets, forKey: Key.presets) }
    }

    /// Fuse color stored as an "RRGGBBAA" hex string.
    @Published var fuseColorHex: String {
        didSet { defaults.set(fuseColorHex, forKey: Key.fuseColorHex) }
    }

    /// Fuse thickness in points, clamped to `minThickness...maxThickness`.
    @Published var fuseThickness: Double {
        didSet {
            let clamped = min(Self.maxThickness, max(Self.minThickness, fuseThickness))
            if clamped != fuseThickness {
                fuseThickness = clamped
                return
            }
            defaults.set(fuseThickness, forKey: Key.fuseThickness)
        }
    }

    /// The texture drawn along the fuse line (solid, rope, or wick).
    @Published var fuseTexture: FuseTexture {
        didSet { defaults.set(fuseTexture.rawValue, forKey: Key.fuseTexture) }
    }

    /// The burning-tip effect at the receding end (glow, flame, or sparks).
    @Published var fuseTipEffect: FuseTipEffect {
        didSet { defaults.set(fuseTipEffect.rawValue, forKey: Key.fuseTipEffect) }
    }

    /// Which screen edge the fuse is drawn on.
    @Published var fusePosition: FusePosition {
        didSet { defaults.set(fusePosition.rawValue, forKey: Key.fusePosition) }
    }

    /// Target display(s): main (default), all, or a specific display. A configured
    /// specific display that is disconnected falls back to main.
    @Published var fuseDisplay: FuseDisplay {
        didSet { defaults.set(fuseDisplay.rawValue, forKey: Key.fuseDisplay) }
    }

    /// Master toggle for the fuse overlay.
    @Published var overlayEnabled: Bool {
        didSet { defaults.set(overlayEnabled, forKey: Key.overlayEnabled) }
    }

    /// Show remaining time next to the menubar icon.
    @Published var showRemainingInMenuBar: Bool {
        didSet { defaults.set(showRemainingInMenuBar, forKey: Key.showRemainingInMenuBar) }
    }

    /// Deliver a notification on completion.
    @Published var notificationEnabled: Bool {
        didSet { defaults.set(notificationEnabled, forKey: Key.notificationEnabled) }
    }

    /// Notification body template (default "Time's up!").
    @Published var notificationTemplate: String {
        didSet { defaults.set(notificationTemplate, forKey: Key.notificationTemplate) }
    }

    /// Play a sound with the notification.
    @Published var notificationSound: Bool {
        didSet { defaults.set(notificationSound, forKey: Key.notificationSound) }
    }

    /// Prevent system idle sleep while a timer is active.
    @Published var preventSleep: Bool {
        didSet { defaults.set(preventSleep, forKey: Key.preventSleep) }
    }

    /// Keep the Mac awake even with the lid closed (rootless clamshell-sleep disable).
    @Published var keepAwakeLidClosed: Bool {
        didSet { defaults.set(keepAwakeLidClosed, forKey: Key.keepAwakeLidClosed) }
    }

    // MARK: Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        presets = Self.loadPresets(defaults)
        fuseColorHex = defaults.string(forKey: Key.fuseColorHex) ?? Self.defaultColorHex
        fuseThickness = defaults.object(forKey: Key.fuseThickness) as? Double ?? Self.defaultThickness
        fuseTexture = (defaults.string(forKey: Key.fuseTexture)).flatMap(FuseTexture.init(rawValue:)) ?? Self.defaultTexture
        fuseTipEffect = (defaults.string(forKey: Key.fuseTipEffect)).flatMap(FuseTipEffect.init(rawValue:)) ?? Self.defaultTipEffect
        fusePosition = (defaults.string(forKey: Key.fusePosition)).flatMap(FusePosition.init(rawValue:)) ?? .top
        fuseDisplay = (defaults.string(forKey: Key.fuseDisplay)).map(FuseDisplay.init(rawValue:)) ?? .main
        overlayEnabled = defaults.object(forKey: Key.overlayEnabled) as? Bool ?? true
        showRemainingInMenuBar = defaults.object(forKey: Key.showRemainingInMenuBar) as? Bool ?? true
        notificationEnabled = defaults.object(forKey: Key.notificationEnabled) as? Bool ?? true
        notificationTemplate = defaults.string(forKey: Key.notificationTemplate) ?? "Time's up!"
        notificationSound = defaults.object(forKey: Key.notificationSound) as? Bool ?? true
        preventSleep = defaults.object(forKey: Key.preventSleep) as? Bool ?? true
        keepAwakeLidClosed = defaults.object(forKey: Key.keepAwakeLidClosed) as? Bool ?? false
    }

    /// Loads the unified preset list. If the new "presets" key exists, use it. Otherwise
    /// migrate from the legacy "durationPresets"/"deadlinePresets" int lists (durations
    /// first, then marks), persisting the result. With neither, use the fresh default.
    private static func loadPresets(_ defaults: UserDefaults) -> [String] {
        if let stored = defaults.array(forKey: Key.presets) as? [String] {
            return stored
        }
        let oldDurations = defaults.array(forKey: Key.durationPresets) as? [Int]
        let oldDeadlines = defaults.array(forKey: Key.deadlinePresets) as? [Int]
        if oldDurations != nil || oldDeadlines != nil {
            var migrated = (oldDurations ?? []).map { "\($0)m" }
            migrated += (oldDeadlines ?? []).map { ":" + String(format: "%02d", $0 % 60) }
            defaults.set(migrated, forKey: Key.presets)
            return migrated
        }
        return defaultPresets
    }

    // MARK: Color helpers

    /// The fuse color as an `NSColor` (sRGB). Falls back to the default red on parse failure.
    var fuseColor: NSColor {
        get { NSColor(hex: fuseColorHex) ?? NSColor(hex: Self.defaultColorHex)! }
        set { fuseColorHex = newValue.hexRGBA }
    }
}

// MARK: - NSColor <-> "RRGGBBAA" hex

extension NSColor {
    /// Parses an "RRGGBB" or "RRGGBBAA" hex string (case-insensitive, optional `#`).
    /// Returns `nil` for malformed input.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// This color rendered as an uppercase "RRGGBBAA" hex string in sRGB.
    var hexRGBA: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        let a = Int(round(c.alphaComponent * 255))
        return String(format: "%02X%02X%02X%02X", r, g, b, a)
    }
}
