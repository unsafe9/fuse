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
        static let fuseTipScale = "fuseTipScale"
        static let fusePosition = "fusePosition"
        static let notchHandling = "notchHandling"
        static let fuseDisplay = "fuseDisplay"
        static let overlayEnabled = "overlayEnabled"
        static let showRemainingInMenuBar = "showRemainingInMenuBar"
        static let notificationEnabled = "notificationEnabled"
        static let notificationTemplate = "notificationTemplate"
        static let notificationSound = "notificationSound"
        static let preventSleep = "preventSleep"
        static let preventDisplaySleep = "preventDisplaySleep"
        static let keepAwakeLidClosed = "keepAwakeLidClosed"
        static let showEndTimeInTooltip = "showEndTimeInTooltip"
        static let showLastFinishedInMenu = "showLastFinishedInMenu"
        static let flareIntensifyEnabled = "flareIntensifyEnabled"
        static let flareEnlargeScale = "flareEnlargeScale"
        static let flareColorHex = "flareColorHex"
        static let lastStartedExpression = "lastStartedExpression"
        static let lastStartedName = "lastStartedName"
        static let lastEndedName = "lastEndedName"
        static let lastEndedAt = "lastEndedAt"
    }

    // MARK: Default values

    /// Fresh-install presets: durations first, then minute-of-hour marks. Each is a
    /// time expression (the same grammar as the custom panel and AppleScript).
    static let defaultPresets = ["1m", "3m", "5m", "10m", "15m", "20m", "30m", "45m", "60m", "90m", "120m", "25m x4", ":15", ":30", ":45", ":00"]
    /// Pure red, fully opaque.
    static let defaultColorHex = "FF1F1FFF"
    static let defaultThickness: Double = 4
    static let minThickness: Double = 1
    static let maxThickness: Double = 20
    /// Fresh-install fuse design: a braided rope with a licking flame tip.
    static let defaultTexture: FuseTexture = .rope
    static let defaultTipEffect: FuseTipEffect = .flame
    static let defaultPosition: FusePosition = .top
    /// Fresh-install: draw the top fuse across the very top edge (over the notch).
    static let defaultNotchHandling: NotchHandling = .over
    /// Burning-tip size as a multiplier on its base size (1× = the baseline).
    static let defaultTipScale: Double = 1.0
    static let minTipScale: Double = 0.5
    static let maxTipScale: Double = 3.0
    /// Warning color the fuse transitions toward near the end (orange, opaque).
    static let defaultFlareColorHex = "FF6A00FF"
    /// Flare enlargement: how much the flame/tip grows near the end, as a multiplier
    /// (1× = no growth). Clamped to `minFlareScale...maxFlareScale`.
    static let defaultFlareEnlargeScale: Double = 2.0
    static let minFlareScale: Double = 1.0
    static let maxFlareScale: Double = 3.0
    /// Seconds before the end at which flare (intensify/warning color) ramps in.
    /// A code constant (not exposed in UI); see the flare design notes.
    static let flareLeadSeconds: TimeInterval = 30

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

    /// Burning-tip size multiplier, clamped to `minTipScale...maxTipScale`.
    @Published var fuseTipScale: Double {
        didSet {
            let clamped = min(Self.maxTipScale, max(Self.minTipScale, fuseTipScale))
            if clamped != fuseTipScale {
                fuseTipScale = clamped
                return
            }
            defaults.set(fuseTipScale, forKey: Key.fuseTipScale)
        }
    }

    /// Which screen edge the fuse is drawn on.
    @Published var fusePosition: FusePosition {
        didSet { defaults.set(fusePosition.rawValue, forKey: Key.fusePosition) }
    }

    /// For the `top` position on a notched MacBook: whether to draw over, below, or
    /// skip the notch. No effect on other positions or on displays without a notch.
    @Published var notchHandling: NotchHandling {
        didSet { defaults.set(notchHandling.rawValue, forKey: Key.notchHandling) }
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

    /// Prevent the display from sleeping while a timer is active, keeping the fuse
    /// overlay visible. Independent of `preventSleep`.
    @Published var preventDisplaySleep: Bool {
        didSet { defaults.set(preventDisplaySleep, forKey: Key.preventDisplaySleep) }
    }

    /// Keep the Mac awake even with the lid closed (rootless clamshell-sleep disable).
    @Published var keepAwakeLidClosed: Bool {
        didSet { defaults.set(keepAwakeLidClosed, forKey: Key.keepAwakeLidClosed) }
    }

    /// Show the end-of-timer wall-clock time (ETA) in the fuse hover tooltip.
    @Published var showEndTimeInTooltip: Bool {
        didSet { defaults.set(showEndTimeInTooltip, forKey: Key.showEndTimeInTooltip) }
    }

    /// Show a recap of the last finished timer at the top of the idle menu.
    @Published var showLastFinishedInMenu: Bool {
        didSet { defaults.set(showLastFinishedInMenu, forKey: Key.showLastFinishedInMenu) }
    }

    /// Master flare toggle: near the end, shift the fuse toward `flareColorHex`.
    @Published var flareIntensifyEnabled: Bool {
        didSet { defaults.set(flareIntensifyEnabled, forKey: Key.flareIntensifyEnabled) }
    }

    /// How much the flame/tip grows near the end (1× = no growth). Sub-option of
    /// `flareIntensifyEnabled`; clamped to `minFlareScale...maxFlareScale`.
    @Published var flareEnlargeScale: Double {
        didSet {
            let clamped = min(Self.maxFlareScale, max(Self.minFlareScale, flareEnlargeScale))
            if clamped != flareEnlargeScale {
                flareEnlargeScale = clamped
                return
            }
            defaults.set(flareEnlargeScale, forKey: Key.flareEnlargeScale)
        }
    }

    /// Warning color the fuse transitions toward, stored as an "RRGGBBAA" hex string.
    @Published var flareColorHex: String {
        didSet { defaults.set(flareColorHex, forKey: Key.flareColorHex) }
    }

    /// The original time expression of the last started timer (F4 repeat last), e.g.
    /// "5m" or ":30". Preserved as the *expression* so a deadline re-resolves correctly.
    @Published var lastStartedExpression: String? {
        didSet { defaults.set(lastStartedExpression, forKey: Key.lastStartedExpression) }
    }

    /// The name of the last started timer (F4), if any.
    @Published var lastStartedName: String? {
        didSet { defaults.set(lastStartedName, forKey: Key.lastStartedName) }
    }

    /// The name of the last finished timer (F5 idle recap), if any.
    @Published var lastEndedName: String? {
        didSet { defaults.set(lastEndedName, forKey: Key.lastEndedName) }
    }

    /// When the last timer finished (F5) — its original expiry instant.
    @Published var lastEndedAt: Date? {
        didSet { defaults.set(lastEndedAt, forKey: Key.lastEndedAt) }
    }

    // MARK: Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        presets = Self.loadPresets(defaults)
        fuseColorHex = defaults.string(forKey: Key.fuseColorHex) ?? Self.defaultColorHex
        fuseThickness = defaults.object(forKey: Key.fuseThickness) as? Double ?? Self.defaultThickness
        fuseTexture = (defaults.string(forKey: Key.fuseTexture)).flatMap(FuseTexture.init(rawValue:)) ?? Self.defaultTexture
        fuseTipEffect = (defaults.string(forKey: Key.fuseTipEffect)).flatMap(FuseTipEffect.init(rawValue:)) ?? Self.defaultTipEffect
        fuseTipScale = defaults.object(forKey: Key.fuseTipScale) as? Double ?? Self.defaultTipScale
        fusePosition = (defaults.string(forKey: Key.fusePosition)).flatMap(FusePosition.init(rawValue:)) ?? Self.defaultPosition
        notchHandling = (defaults.string(forKey: Key.notchHandling)).flatMap(NotchHandling.init(rawValue:)) ?? Self.defaultNotchHandling
        fuseDisplay = (defaults.string(forKey: Key.fuseDisplay)).map(FuseDisplay.init(rawValue:)) ?? .main
        overlayEnabled = defaults.object(forKey: Key.overlayEnabled) as? Bool ?? true
        showRemainingInMenuBar = defaults.object(forKey: Key.showRemainingInMenuBar) as? Bool ?? true
        notificationEnabled = defaults.object(forKey: Key.notificationEnabled) as? Bool ?? true
        notificationTemplate = defaults.string(forKey: Key.notificationTemplate) ?? "Time's up!"
        notificationSound = defaults.object(forKey: Key.notificationSound) as? Bool ?? true
        preventSleep = defaults.object(forKey: Key.preventSleep) as? Bool ?? true
        preventDisplaySleep = defaults.object(forKey: Key.preventDisplaySleep) as? Bool ?? true
        keepAwakeLidClosed = defaults.object(forKey: Key.keepAwakeLidClosed) as? Bool ?? false
        showEndTimeInTooltip = defaults.object(forKey: Key.showEndTimeInTooltip) as? Bool ?? true
        showLastFinishedInMenu = defaults.object(forKey: Key.showLastFinishedInMenu) as? Bool ?? false
        flareIntensifyEnabled = defaults.object(forKey: Key.flareIntensifyEnabled) as? Bool ?? true
        flareEnlargeScale = defaults.object(forKey: Key.flareEnlargeScale) as? Double ?? Self.defaultFlareEnlargeScale
        flareColorHex = defaults.string(forKey: Key.flareColorHex) ?? Self.defaultFlareColorHex
        lastStartedExpression = defaults.string(forKey: Key.lastStartedExpression)
        lastStartedName = defaults.string(forKey: Key.lastStartedName)
        lastEndedName = defaults.string(forKey: Key.lastEndedName)
        lastEndedAt = defaults.object(forKey: Key.lastEndedAt) as? Date
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

    // MARK: Reset

    /// Restores the Fuse appearance settings — color, thickness, texture, burning tip,
    /// tip size, position, and notch offset — to their fresh-install defaults. Leaves everything else
    /// (overlay toggle, target display, presets, notifications, power) untouched.
    func resetAppearance() {
        fuseColorHex = Self.defaultColorHex
        fuseThickness = Self.defaultThickness
        fuseTexture = Self.defaultTexture
        fuseTipEffect = Self.defaultTipEffect
        fuseTipScale = Self.defaultTipScale
        fusePosition = Self.defaultPosition
        notchHandling = Self.defaultNotchHandling
    }

    // MARK: Color helpers

    /// The fuse color as an `NSColor` (sRGB). Falls back to the default red on parse failure.
    var fuseColor: NSColor {
        get { NSColor(hex: fuseColorHex) ?? NSColor(hex: Self.defaultColorHex)! }
        set { fuseColorHex = newValue.hexRGBA }
    }

    /// The warning (flare) color as an `NSColor` (sRGB). Falls back to the default
    /// orange on parse failure.
    var flareColor: NSColor {
        get { NSColor(hex: flareColorHex) ?? NSColor(hex: Self.defaultFlareColorHex)! }
        set { flareColorHex = newValue.hexRGBA }
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
