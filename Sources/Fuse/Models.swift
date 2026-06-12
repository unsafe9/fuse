import CoreGraphics
import Foundation

// MARK: - Logging

/// Shared logging subsystem for the whole app.
let logSubsystem = "com.unsafe9.fuse"

// MARK: - Timer session

/// A single in-flight timer. Exactly one exists while a timer runs.
struct TimerSession: Equatable {
    /// Optional user-facing name (used as the notification title when set).
    let name: String?
    /// When the timer was started.
    let startDate: Date
    /// When the timer fires.
    let endDate: Date

    /// Full configured length of the timer.
    var total: TimeInterval { endDate.timeIntervalSince(startDate) }
}

// MARK: - Fuse position

/// Which screen edge the fuse overlay is anchored to.
enum FusePosition: String, Codable, CaseIterable {
    case top
    case bottom
    case left
    case right

    /// Human-readable label for settings UI.
    var displayName: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .left: return "Left"
        case .right: return "Right"
        }
    }

    /// True when the fuse runs horizontally (top/bottom), false for vertical (left/right).
    var isHorizontal: Bool {
        self == .top || self == .bottom
    }
}

// MARK: - Fuse display

/// Which display(s) the fuse overlay is drawn on.
enum FuseDisplay: Hashable {
    case main
    case all
    case id(CGDirectDisplayID)

    var rawValue: String {
        switch self {
        case .main: return "main"
        case .all: return "all"
        case .id(let id): return String(id)
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "main": self = .main
        case "all": self = .all
        default: self = UInt32(rawValue).map(FuseDisplay.id) ?? .main
        }
    }
}

// MARK: - Fuse texture & tip effect

/// The texture drawn along the fuse line. Every texture renders strictly within the
/// configured thickness band (it only shades/overlays the existing bar), so changing
/// texture never makes the line exceed its configured width.
enum FuseTexture: String, Codable, CaseIterable {
    /// A plain, flat fill (classic, minimal).
    case solid
    /// A braided twisted-rope look — the default, fitting the "fuse" theme.
    case rope
    /// A wrapped wick/cord with periodic darker bindings.
    case wick

    var displayName: String {
        switch self {
        case .solid: return "Solid"
        case .rope: return "Rope"
        case .wick: return "Wick"
        }
    }
}

/// The burning-tip effect at the receding end of the fuse. Effects are drawn around the
/// tip and elongate *along* the burn axis (not across it), so they stay within roughly
/// the thickness band and never noticeably exceed the configured width.
enum FuseTipEffect: String, Codable, CaseIterable {
    /// A soft glowing dot (classic).
    case glow
    /// A layered flame tongue licking along the fuse — the default.
    case flame
    /// A flame with trailing sparks/embers.
    case spark

    var displayName: String {
        switch self {
        case .glow: return "Glow"
        case .flame: return "Flame"
        case .spark: return "Sparks"
        }
    }

    /// Whether this effect flickers and so needs a per-frame redraw.
    var isAnimated: Bool { self != .glow }
}

/// How large the burning-tip effect is drawn, as a multiplier on its base size. The
/// overlay strip's interior headroom scales by the same factor, so a bigger tip just
/// bulges further into the screen without clipping.
enum FuseTipSize: String, Codable, CaseIterable {
    case small
    case medium
    case large
    case extraLarge

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    /// Multiplier applied to the tip's base size (medium = the baseline).
    var scale: CGFloat {
        switch self {
        case .small: return 0.65
        case .medium: return 1.0
        case .large: return 1.5
        case .extraLarge: return 2.2
        }
    }
}

// MARK: - Internal notification names

extension Notification.Name {
    /// Posted when a timer begins. Observers must treat this idempotently.
    static let fuseTimerStarted = Notification.Name("com.unsafe9.fuse.timerStarted")
    /// Posted on every engine tick (~0.25s) while a timer runs.
    static let fuseTimerTick = Notification.Name("com.unsafe9.fuse.timerTick")
    /// Posted when a timer reaches its end. `userInfo[fuseSessionKey]` holds the finished `TimerSession`.
    static let fuseTimerCompleted = Notification.Name("com.unsafe9.fuse.timerCompleted")
    /// Posted when a running timer is cancelled by the user (not on silent replace).
    static let fuseTimerCancelled = Notification.Name("com.unsafe9.fuse.timerCancelled")
    /// Posted when the Settings "Fuse" tab becomes visible: show a static overlay
    /// preview so appearance changes are visible without a running timer.
    static let fusePreviewBegan = Notification.Name("com.unsafe9.fuse.previewBegan")
    /// Posted when the "Fuse" tab is dismissed or the Settings window closes: end the preview.
    static let fusePreviewEnded = Notification.Name("com.unsafe9.fuse.previewEnded")
}

/// `userInfo` key carrying a `TimerSession` on `.fuseTimerCompleted`.
let fuseSessionKey = "session"

// MARK: - Shared helpers

enum TimeFormat {
    /// Formats a non-negative interval as "12:34" (m:ss) or "1:02:03" (h:mm:ss).
    /// Negative inputs are clamped to 0.
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Formats a minute count as a preset label: "5 min", "1 h", "1 h 30 min".
    static func presetLabel(minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        switch (hours, mins) {
        case (0, _):
            return "\(mins) min"
        case (_, 0):
            return "\(hours) h"
        default:
            return "\(hours) h \(mins) min"
        }
    }
}

enum DeadlineMath {
    /// Returns the next clock instant strictly after `date` whose minute-of-hour equals
    /// `minute` (0...59, seconds zero); `minute` 0 means the top of the hour. If `date`
    /// is exactly on the mark, the NEXT occurrence is returned (never a zero-length
    /// result). DST-safe via `Calendar.nextDate`.
    ///
    /// Examples at 14:50: 15 -> 15:15, 30 -> 15:30, 45 -> 15:45, 0 -> 15:00.
    /// At exactly 15:15:00, 15 -> 16:15.
    static func nextMinuteMark(minute: Int, after date: Date, calendar: Calendar = .current) -> Date {
        let m = ((minute % 60) + 60) % 60
        let components = DateComponents(minute: m, second: 0)
        // `.nextTime` skips clock times erased by a DST gap to the next valid match.
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(3600)
    }
}

// MARK: - Presets

/// A parsed preset expression: either a fixed-length duration or a minute-of-hour
/// mark. A preset is just a time expression (the same grammar as the custom panel and
/// AppleScript). `Preset.parse` classifies the expression so callers can both render a
/// label and start the right kind of timer without re-parsing.
enum Preset: Equatable {
    /// A fixed-length duration in seconds (from `5m`, `1h30m`, `90`, `45s`, ...).
    case duration(TimeInterval)
    /// A minute-of-hour mark, 0...59 (from `:MM`; 0 = top of the hour).
    case mark(Int)

    /// Classifies `expression` via `TimeParser`. Returns nil for invalid input.
    static func parse(_ expression: String, now: Date = Date()) -> Preset? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(":"), let minute = Int(trimmed.dropFirst()),
           (0...59).contains(minute), trimmed.count == 3 {
            return .mark(minute)
        }
        guard let result = try? TimeParser.parse(trimmed, now: now) else { return nil }
        switch result {
        case .duration(let seconds): return .duration(seconds)
        case .deadline: return nil  // absolute HH:MM is not a valid preset expression
        }
    }
}

/// Pure helpers for rendering a preset expression as a human-readable label. Shared by
/// `StatusItemController` (menu) and `SettingsView` (settings) so the two views always
/// agree.
enum PresetLabel {
    /// The label for a DURATION preset (e.g. "5 min", "1 h 30 min", "45 sec"). Whole
    /// minutes reuse `TimeFormat.presetLabel`; sub-minute lengths render as seconds.
    static func duration(seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 {
            return "\(total) sec"
        }
        if total % 60 == 0 {
            return TimeFormat.presetLabel(minutes: total / 60)
        }
        let minutes = total / 60
        let secs = total % 60
        return "\(TimeFormat.presetLabel(minutes: minutes)) \(secs) sec"
    }

    /// The BASE label for a deadline mark (no target time). The status menu appends the
    /// computed target ("  (15:15)") at menu-open; settings shows the base alone.
    static func markBase(minute: Int) -> String {
        minute == 0 ? "Next hour" : "Next :\(String(format: "%02d", minute))"
    }

    /// A compact label for a deadline mark used in settings (no target time), e.g.
    /// ":15" or "top of hour" for the top-of-hour mark.
    static func markSettings(minute: Int) -> String {
        minute == 0 ? "top of hour" : ":\(String(format: "%02d", minute))"
    }
}
