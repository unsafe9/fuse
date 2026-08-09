import CoreGraphics
import Foundation

// MARK: - Logging

/// Shared logging subsystem for the whole app.
let logSubsystem = "com.unsafe9.fuse"

// MARK: - Repeat policy

/// Auto-repeat termination condition. Applies only to duration sessions (an absolute
/// `deadline` has no meaningful repeat — its end is fixed).
enum RepeatPolicy: Equatable {
    case none
    case count(Int)     // total rounds (e.g. 4 = first + 3 repeats)
    case until(Date)    // do not start a round that would run past this instant
    case forever        // until the user stops
}

// MARK: - Timer session

/// A single in-flight timer. Exactly one exists while a timer runs.
struct TimerSession: Equatable {
    /// Optional user-facing name (used as the notification title when set).
    let name: String?
    /// When the timer was started.
    let startDate: Date
    /// When the timer fires.
    let endDate: Date
    /// Auto-repeat policy. `.none` for a single-shot or deadline session.
    var repeatPolicy: RepeatPolicy = .none
    /// Current round, 1-based. The first session is round 1.
    var round: Int = 1

    /// Full configured length of the timer.
    var total: TimeInterval { endDate.timeIntervalSince(startDate) }

    /// A round label for the active surfaces (menu, hover): "#3/5" for `count`,
    /// "#3" for `until`/`forever`, and `nil` when not repeating.
    static func roundLabel(round: Int, policy: RepeatPolicy) -> String? {
        switch policy {
        case .none:
            return nil
        case .count(let n):
            return "#\(round)/\(n)"
        case .until, .forever:
            return "#\(round)"
        }
    }

    /// The final wall-clock instant the whole relay finishes, for ETA "all done ~16:10".
    /// `count` projects the remaining full rounds onto `endDate`; `until` returns the
    /// policy instant; `none`/`forever` have no defined finish and return `nil`.
    func relayFinish() -> Date? {
        switch repeatPolicy {
        case .none, .forever:
            return nil
        case .count(let n):
            let remainingRounds = max(0, n - round)
            return endDate.addingTimeInterval(total * Double(remainingRounds))
        case .until(let date):
            return date
        }
    }
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

// MARK: - Notch handling

/// How the `top` fuse deals with a MacBook's notch. Only meaningful for the top edge
/// on a display that actually has a notch; on other edges / notchless displays every
/// case draws the same full-width strip.
enum NotchHandling: String, Codable, CaseIterable {
    /// Draw the strip across the very top edge as-is — the middle sits behind the notch.
    case over
    /// Drop the strip below the notch (offset by the top safe-area inset) so the whole
    /// line is visible, just lower.
    case below
    /// Keep the strip at the top edge but skip the notch's width: the line fills up to
    /// the notch, then jumps across it and continues on the far side, so the notch never
    /// covers any of it.
    case skip

    var displayName: String {
        switch self {
        case .over: return "Draw over the notch"
        case .below: return "Draw below the notch"
        case .skip: return "Skip the notch"
        }
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

// MARK: - Fuse progress mode

/// How the visible fuse length maps to timer progress.
enum FuseProgressMode: String, Codable, CaseIterable {
    /// Existing behavior: the fuse starts full and burns down as time runs out.
    case burnDown
    /// Optional buildup behavior: the fuse starts absent and grows as the deadline nears.
    case buildUp

    var displayName: String {
        switch self {
        case .burnDown: return "Burn down"
        case .buildUp: return "Build up"
        }
    }
}

// MARK: - Progress milestones

/// Which elapsed-progress points fire an interim "milestone" banner partway through a
/// timer (feature 4, opt-in). Independent of the completion notification.
enum MilestoneSet: String, Codable, CaseIterable {
    case off
    case halfway
    case thirds
    case quarters
    case fifths
    case finalStretch

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .halfway: return "Halfway (50%)"
        case .thirds: return "Thirds (33 / 66%)"
        case .quarters: return "Quarters (25 / 50 / 75%)"
        case .fifths: return "Fifths (20 / 40 / 60 / 80%)"
        case .finalStretch: return "Final stretch (75 / 90%)"
        }
    }

    /// Elapsed-progress percentages (1...99) at which to fire a banner. `100` is never
    /// a milestone — the completion notification owns the finish.
    var percents: [Int] {
        switch self {
        case .off: return []
        case .halfway: return [50]
        case .thirds: return [33, 66]
        case .quarters: return [25, 50, 75]
        case .fifths: return [20, 40, 60, 80]
        case .finalStretch: return [75, 90]
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

    /// Appends a "×N" repeat suffix to a base label when the policy is `count(N)`
    /// (e.g. "5 min" -> "5 min ×4"). Other policies return the base unchanged.
    static func withRepeat(_ base: String, policy: RepeatPolicy) -> String {
        if case .count(let n) = policy {
            return "\(base) ×\(n)"
        }
        return base
    }
}

// MARK: - Repeat expression

/// Splits a preset/custom/AppleScript expression into its time expression and an
/// optional repeat policy. The repeat suffix is a trailing `xN` (case-insensitive),
/// e.g. "25m x4" -> ("25m", .count(4)). A bare expression carries `.none`.
enum RepeatExpression {
    /// Splits `raw` into `(expression, policy)`. Throws `ParseError` when a repeat
    /// suffix is attached to a deadline expression (`:30`, `14:00`) — only durations
    /// repeat. The returned `expression` is the trimmed time expression with the
    /// suffix removed; callers still parse it via `TimeParser`.
    static func split(_ raw: String) throws -> (expression: String, policy: RepeatPolicy) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = repeatCount(trimmed) else {
            return (trimmed, .none)
        }
        // Strip the trailing "xN" token and any whitespace before it.
        let expression = String(trimmed[..<trimmed.range(of: " ", options: .backwards)!.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A deadline expression cannot repeat.
        if (try? TimeParser.parse(expression)).map({ if case .deadline = $0 { return true } else { return false } }) == true {
            throw ParseError(reason: "Repeat (xN) only works with duration timers, not a clock time.")
        }
        return (expression, .count(n))
    }

    /// Parses a trailing `xN` token (e.g. the "x4" in "25m x4") into N (>= 1), or nil
    /// when there is no valid repeat suffix.
    private static func repeatCount(_ trimmed: String) -> Int? {
        guard let lastSpace = trimmed.range(of: " ", options: .backwards) else { return nil }
        let token = trimmed[lastSpace.upperBound...].lowercased()
        guard token.hasPrefix("x"), let n = Int(token.dropFirst()), n >= 1 else { return nil }
        return n
    }
}
