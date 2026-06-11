import Foundation
import os

/// AppleScript command: `tell application "Fuse" to start timer "5m" named "tea"`
/// (feature 6).
///
/// Maps to the sdef "start timer" command (code `FuseStrt`). The direct parameter is
/// the time expression (same grammar as the custom panel, via `TimeParser`); the
/// optional `named` parameter (code `pNam`) is the timer name.
/// `performDefaultImplementation` parses the expression, dispatches the matching
/// `TimerEngine.shared.start(...)` on the main thread, and on bad input sets
/// `scriptErrorNumber` / `scriptErrorString` (from `ParseError.reason`) and returns nil.
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

        let result: ParseResult
        do {
            result = try TimeParser.parse(expression)
        } catch let error as ParseError {
            scriptErrorNumber = errOSAGeneralError
            scriptErrorString = error.reason
            return nil
        } catch {
            scriptErrorNumber = errOSAGeneralError
            scriptErrorString = "Could not parse the time expression."
            return nil
        }

        log.info("AppleScript start timer: \(expression, privacy: .public)")
        onMain {
            switch result {
            case .duration(let seconds):
                TimerEngine.shared.start(duration: seconds, name: timerName)
            case .deadline(let date):
                TimerEngine.shared.start(until: date, name: timerName)
            }
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
