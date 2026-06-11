import Foundation
import IOKit.pwr_mgt
import os

/// Manages sleep-prevention while a timer is active (feature 5).
///
/// Observes timer start (`.fuseTimerStarted`) and stop (`.fuseTimerCompleted` /
/// `.fuseTimerCancelled`).
///
/// - When `SettingsStore.shared.preventSleep` is on: holds an
///   `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, ...,
///   "Fuse timer running")` for the duration, released on stop/terminate. Release is
///   idempotent (no double-release).
/// - When `SettingsStore.shared.keepAwakeLidClosed` is on: at timer start, runs
///   `do shell script "pmset disablesleep 1" with administrator privileges`
///   (NSAppleScript, off the main thread); on stop/terminate runs
///   `pmset disablesleep 0` — but only if we actually set it. Auth failures are
///   logged and never crash or retry-loop.
///
/// `TimerEngine.cancel()` on app termination guarantees stop runs, so this manager
/// fully restores power state on exit.
///
/// OWNER: system. Compiling stub.
final class PowerManager {
    private let log = Logger(subsystem: logSubsystem, category: "PowerManager")

    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var didSetDisableSleep = false

    /// Begins observing timer start/stop notifications.
    init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(timerStarted), name: .fuseTimerStarted, object: nil)
        nc.addObserver(self, selector: #selector(timerStopped), name: .fuseTimerCompleted, object: nil)
        nc.addObserver(self, selector: #selector(timerStopped), name: .fuseTimerCancelled, object: nil)
    }

    @objc private func timerStarted() {
        let store = SettingsStore.shared

        if store.preventSleep {
            acquireAssertion()
        }
        // Guard against re-prompting on silent replace: only enable when not already set.
        if store.keepAwakeLidClosed && !didSetDisableSleep {
            setDisableSleep(true)
        }
    }

    @objc private func timerStopped() {
        releaseAssertion()
        if didSetDisableSleep {
            setDisableSleep(false)
        }
    }

    /// Synchronous best-effort restore for app termination. Runs `pmset disablesleep 0`
    /// inline (blocking the calling thread) so it completes before the process exits,
    /// where the normal async stop path would be dropped.
    func teardownForTermination() {
        releaseAssertion()
        guard didSetDisableSleep else { return }
        didSetDisableSleep = false
        runDisableSleepScript(false)
    }

    private func acquireAssertion() {
        guard !hasAssertion else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Fuse timer running" as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            hasAssertion = true
        } else {
            log.error("IOPMAssertionCreateWithName failed: \(result)")
        }
    }

    private func releaseAssertion() {
        guard hasAssertion else { return }
        IOPMAssertionRelease(assertionID)
        hasAssertion = false
        assertionID = 0
    }

    /// Asynchronously toggles `pmset disablesleep`. The intent flag is flipped
    /// synchronously (on the calling main thread) *before* dispatch, so a stop arriving
    /// while the admin-auth dialog is still up still pairs the matching disable instead
    /// of skipping it (and the flag never lands permanently true with nothing to clear it).
    private func setDisableSleep(_ disable: Bool) {
        didSetDisableSleep = disable
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runDisableSleepScript(disable)
        }
    }

    /// Runs the privileged `pmset disablesleep` AppleScript on the current thread.
    private func runDisableSleepScript(_ disable: Bool) {
        let value = disable ? 1 : 0
        let script = "do shell script \"pmset disablesleep \(value)\" with administrator privileges"
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)
        if let error {
            log.error("pmset disablesleep \(value) failed: \(error)")
        }
    }
}
