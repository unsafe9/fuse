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

// MARK: - Preset mode

/// Which preset section(s) the status menu shows.
enum PresetMode: String, Codable, CaseIterable {
    case duration
    case deadline
    case both

    /// Human-readable label for settings UI.
    var displayName: String {
        switch self {
        case .duration: return "Duration only"
        case .deadline: return "Deadline only"
        case .both: return "Both"
        }
    }

    var showsDuration: Bool { self == .duration || self == .both }
    var showsDeadline: Bool { self == .deadline || self == .both }
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
    /// `mark % 60` (seconds zero). A `mark` of 60 (≡ 0) means the top of the hour. If
    /// `date` is exactly on the mark, the NEXT occurrence is returned (never a
    /// zero-length result). DST-safe via `Calendar.nextDate`.
    ///
    /// Examples at 14:50: 15 -> 15:15, 30 -> 15:30, 45 -> 15:45, 60 -> 15:00.
    /// At exactly 15:15:00, 15 -> 16:15.
    static func nextMinuteMark(_ mark: Int, after date: Date, calendar: Calendar = .current) -> Date {
        let minute = ((mark % 60) + 60) % 60
        let components = DateComponents(minute: minute, second: 0)
        // `.nextTime` skips clock times erased by a DST gap to the next valid match.
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(3600)
    }
}
