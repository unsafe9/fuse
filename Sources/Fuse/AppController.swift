import Foundation
import os

/// The single entry point for starting timers from every surface (menu presets, the
/// custom panel, AppleScript). Routing all starts through here means the "last started"
/// record (F4 repeat last) is written in exactly ONE place, and the "last finished"
/// record (F5 idle recap) is observed in exactly ONE place.
///
/// `shared` is realized once at launch (held by `AppDelegate`) so its
/// `.fuseTimerCompleted` observer is installed for the app's lifetime.
final class AppController {
    static let shared = AppController()

    private let log = Logger(subsystem: logSubsystem, category: "AppController")
    private let settings = SettingsStore.shared

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(timerCompleted(_:)),
            name: .fuseTimerCompleted,
            object: nil
        )
    }

    /// Parses `expression` (`RepeatExpression.split` -> `TimeParser.parse`) and starts
    /// the matching timer. Durations honor the repeat policy; a deadline forces `.none`.
    /// On success the original expression/name are recorded for repeat-last (F4).
    /// Throws `ParseError` on invalid input so callers can surface the inline message.
    func start(expression: String, name: String?) throws {
        let (timeExpression, policy) = try RepeatExpression.split(expression)
        let result = try TimeParser.parse(timeExpression)
        switch result {
        case .duration(let seconds):
            TimerEngine.shared.start(duration: seconds, name: name, repeatPolicy: policy)
        case .deadline(let date):
            TimerEngine.shared.start(until: date, name: name)
        }
        // Persist the ORIGINAL expression (with any xN suffix) so repeat-last can show
        // and re-resolve it; repeat-last itself replays as a single shot.
        settings.lastStartedExpression = expression
        settings.lastStartedName = name
    }

    /// Re-starts the last started timer as a single shot (`.none`), re-resolving the
    /// expression (so a deadline retargets the next occurrence). No-op when nothing was
    /// started yet.
    func repeatLast() {
        guard let expression = settings.lastStartedExpression else { return }
        let name = settings.lastStartedName
        do {
            // Strip any repeat suffix: repeat-last is always a single shot.
            let (timeExpression, _) = try RepeatExpression.split(expression)
            let result = try TimeParser.parse(timeExpression)
            switch result {
            case .duration(let seconds):
                TimerEngine.shared.start(duration: seconds, name: name)
            case .deadline(let date):
                TimerEngine.shared.start(until: date, name: name)
            }
        } catch {
            log.error("repeatLast failed to parse stored expression: \(expression, privacy: .public)")
        }
    }

    /// Records the finished session for the idle recap (F5). Fires on every round.
    @objc private func timerCompleted(_ note: Notification) {
        guard let session = note.userInfo?[fuseSessionKey] as? TimerSession else { return }
        settings.lastEndedName = session.name
        settings.lastEndedAt = session.endDate
    }
}
