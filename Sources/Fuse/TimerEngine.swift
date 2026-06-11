import Foundation
import os

/// The single timer authority for the whole app (feature 8: exactly one timer).
///
/// Owns at most one `TimerSession`. Starting a new timer while one runs is a SILENT
/// replace: internally stop the old one (without firing user-visible cancel side
/// effects beyond what `.fuseTimerStarted` observers reset idempotently), then start
/// fresh. Drives one repeating `Timer` at 0.25s on `RunLoop.main` in `.common` mode
/// (so it keeps ticking while the status menu is open), which checks for expiry and
/// posts the internal `Notification.Name` events.
///
/// Events posted (see Models.swift):
/// - `.fuseTimerStarted`   when a timer begins (observers must be idempotent).
/// - `.fuseTimerTick`      on every tick while running.
/// - `.fuseTimerCompleted` when `remaining` reaches 0; `userInfo[fuseSessionKey]`
///                         carries the finished `TimerSession`.
/// - `.fuseTimerCancelled` only on explicit user `cancel()` of a running timer
///                         (NOT on silent replace).
///
/// OWNER: core. This is a compiling stub; behavior described above is the contract.
final class TimerEngine {
    static let shared = TimerEngine()

    private let log = Logger(subsystem: logSubsystem, category: "TimerEngine")

    /// The currently running session, or `nil` when idle.
    private(set) var session: TimerSession?

    /// Drives expiry checks and `.fuseTimerTick`. Scheduled on `RunLoop.main` `.common`.
    private var ticker: Timer?

    private init() {}

    /// Starts a relative-duration timer. Replaces any running timer silently.
    /// `duration` must be > 0 (callers validate; non-positive is ignored).
    func start(duration: TimeInterval, name: String?) {
        guard duration > 0 else {
            log.error("Ignoring start with non-positive duration: \(duration)")
            return
        }
        let start = Date()
        begin(session: TimerSession(name: name, startDate: start, endDate: start.addingTimeInterval(duration)))
    }

    /// Starts a timer that fires at an absolute `Date`. Replaces any running timer
    /// silently. `until` must be in the future (callers validate).
    func start(until: Date, name: String?) {
        let start = Date()
        guard until > start else {
            log.error("Ignoring start with non-future deadline.")
            return
        }
        begin(session: TimerSession(name: name, startDate: start, endDate: until))
    }

    /// Cancels the running timer if any. Posts `.fuseTimerCancelled`. Safe to call
    /// when idle (no-op). Called on app termination to restore power state.
    func cancel() {
        guard session != nil else { return }
        stop()
        NotificationCenter.default.post(name: .fuseTimerCancelled, object: self)
    }

    /// Seconds remaining until the session fires, clamped to `>= 0`. Zero when idle.
    var remaining: TimeInterval {
        guard let session else { return 0 }
        return max(0, session.endDate.timeIntervalSinceNow)
    }

    /// Fraction of the timer still remaining (`remaining / total`), clamped `0...1`.
    /// This is what the fuse overlay draws as its filled length. Zero when idle.
    var progress: Double {
        guard let session, session.total > 0 else { return 0 }
        return min(1, max(0, remaining / session.total))
    }

    // MARK: - Internals

    /// Installs a fresh session, replacing any running one silently, and posts
    /// `.fuseTimerStarted`. Observers treat the start idempotently.
    private func begin(session newSession: TimerSession) {
        stop()
        session = newSession
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        NotificationCenter.default.post(name: .fuseTimerStarted, object: self)
    }

    /// Fires every 0.25s: posts `.fuseTimerTick`, and on expiry completes the session.
    private func tick() {
        guard let current = session else { return }
        if current.endDate.timeIntervalSinceNow <= 0 {
            stop()
            NotificationCenter.default.post(
                name: .fuseTimerCompleted,
                object: self,
                userInfo: [fuseSessionKey: current]
            )
        } else {
            NotificationCenter.default.post(name: .fuseTimerTick, object: self)
        }
    }

    /// Tears down the running session and ticker without posting any user-visible
    /// event. Used by silent replace, completion, and cancel.
    private func stop() {
        ticker?.invalidate()
        ticker = nil
        session = nil
    }
}
