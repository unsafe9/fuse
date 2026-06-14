import AppKit
import Foundation
import os

/// AppleScript command: `tell application "Fuse" to start timer "5m" named "tea"`
/// (feature 6).
///
/// Maps to the sdef "start timer" command (code `FuseStrt`). The direct parameter is
/// the time expression (same grammar as the custom panel, via `TimeParser`); the
/// optional `named` parameter (code `pNam`) is the timer name; the optional `repeating`
/// parameter (code `pRep`) is the total round count for a duration timer's auto-repeat.
/// `performDefaultImplementation` parses the expression, dispatches the matching start
/// through `AppController.shared.start(...)` on the main thread (so repeat-last is
/// recorded), and on bad input sets `scriptErrorNumber` / `scriptErrorString` (from
/// `ParseError.reason`) and returns nil.
///
/// OWNER: scripting.
final class FuseStartTimerCommand: NSScriptCommand {
    private let log = Logger(subsystem: logSubsystem, category: "Scripting")

    override func performDefaultImplementation() -> Any? {
        guard let expression = (directParameter as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expression.isEmpty else {
            scriptErrorNumber = errOSAGeneralError
            scriptErrorString = "A time expression is required, e.g. \"5m\", \"1h30m\", \"90\", \"23:30\"."
            return nil
        }

        let rawName = evaluatedArguments?["name"] as? String
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let timerName = (name?.isEmpty == false) ? name : nil

        // Optional `repeating N` (>= 2) appends a "xN" suffix so AppController applies
        // `.count(N)`; N <= 1 means a single shot, the same as omitting the parameter.
        // Repeating only applies to duration timers — AppController throws (and we
        // surface it) if the expression is a clock time.
        var startExpression = expression
        if let repeating = (evaluatedArguments?["repeating"] as? NSNumber)?.intValue, repeating >= 2 {
            startExpression = "\(expression) x\(repeating)"
        }

        log.info("AppleScript start timer: \(startExpression, privacy: .public)")
        var startError: ParseError?
        onMain {
            do {
                try AppController.shared.start(expression: startExpression, name: timerName)
            } catch let error as ParseError {
                startError = error
            } catch {
                startError = ParseError(reason: "Could not parse the time expression.")
            }
        }
        if let startError {
            scriptErrorNumber = errOSAGeneralError
            scriptErrorString = startError.reason
            return nil
        }
        return nil
    }
}

/// AppleScript command: `tell application "Fuse" to repeat last timer`.
///
/// Maps to the sdef "repeat last timer" command (code `FuseRpLt`). Re-starts the most
/// recently started timer as a single shot via `AppController.shared.repeatLast()`;
/// a no-op when nothing has been started yet.
///
/// OWNER: scripting.
final class FuseRepeatLastTimerCommand: NSScriptCommand {
    private let log = Logger(subsystem: logSubsystem, category: "Scripting")

    override func performDefaultImplementation() -> Any? {
        log.info("AppleScript repeat last timer")
        onMain {
            AppController.shared.repeatLast()
        }
        return nil
    }
}

/// AppleScript command: `tell application "Fuse" to stop timer` (feature 6).
///
/// Maps to the sdef "stop timer" command (code `FuseStop`). Calls
/// `TimerEngine.shared.cancel()` on the main thread.
///
/// OWNER: scripting.
final class FuseStopTimerCommand: NSScriptCommand {
    private let log = Logger(subsystem: logSubsystem, category: "Scripting")

    override func performDefaultImplementation() -> Any? {
        log.info("AppleScript stop timer")
        onMain {
            TimerEngine.shared.cancel()
        }
        return nil
    }
}

/// Runs `body` synchronously on the main thread. AppleScript commands normally already
/// execute on the main thread; this guards against any off-main dispatch without
/// deadlocking when already on main.
private func onMain(_ body: @escaping () -> Void) {
    if Thread.isMainThread {
        body()
    } else {
        DispatchQueue.main.sync(execute: body)
    }
}

/// Returns `body`'s result on the main thread (synchronous, deadlock-safe when already
/// on main). Used by the read-only scripting properties below.
private func onMain<T>(_ body: @escaping () -> T) -> T {
    if Thread.isMainThread {
        return body()
    }
    return DispatchQueue.main.sync(execute: body)
}

/// Read-only AppleScript properties on the `application` class (feature 2). Each is a
/// KVC key referenced by `Resources/Fuse.sdef`; the cocoa keys are part of the public
/// scripting contract (the Alfred workflow depends on the sdef property names). Values
/// are read from the shared stores on the main thread.
extension NSApplication {
    /// The stored preset expression strings, in order. sdef: `presets`.
    @objc var scriptPresets: [String] {
        onMain { SettingsStore.shared.presets }
    }

    /// True iff a timer is currently active. sdef: `running`.
    @objc var scriptTimerRunning: Bool {
        onMain { TimerEngine.shared.session != nil }
    }

    /// Whole seconds remaining, 0 when no timer is running. sdef: `remaining`.
    @objc var scriptRemainingSeconds: Int {
        onMain { Int(TimerEngine.shared.remaining.rounded()) }
    }

    /// The running timer's name, "" when none or unnamed. sdef: `timer name`.
    @objc var scriptTimerName: String {
        onMain { TimerEngine.shared.session?.name ?? "" }
    }

    /// The running timer's end time as "HH:mm" (24-hour, zero-padded for stable Alfred
    /// parsing), "" when no timer is running. sdef: `ends`.
    @objc var scriptEndsAt: String {
        onMain {
            guard let session = TimerEngine.shared.session else { return "" }
            return Self.clockFormatter.string(from: session.endDate)
        }
    }

    /// The running timer's current round (1-based), 0 when no timer is running.
    /// sdef: `round`.
    @objc var scriptRound: Int {
        onMain { TimerEngine.shared.session?.round ?? 0 }
    }

    /// The last finished timer's end time as "HH:mm" (24-hour, zero-padded), "" when
    /// nothing has finished yet. sdef: `last ended at`.
    @objc var scriptLastEndedAt: String {
        onMain {
            guard let date = SettingsStore.shared.lastEndedAt else { return "" }
            return Self.clockFormatter.string(from: date)
        }
    }

    /// The most recently started timer's time expression (e.g. "5m", "25m x4"), "" when
    /// nothing has been started yet. sdef: `last started`.
    @objc var scriptLastStartedExpression: String {
        onMain { SettingsStore.shared.lastStartedExpression ?? "" }
    }

    /// The most recently started timer's name, "" when none or unnamed.
    /// sdef: `last started name`.
    @objc var scriptLastStartedName: String {
        onMain { SettingsStore.shared.lastStartedName ?? "" }
    }

    /// Fixed 24-hour "HH:mm" formatter for the scripting time properties — a stable,
    /// locale-independent contract for the Alfred workflow (unlike the locale-aware
    /// hover tooltip ETA).
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
