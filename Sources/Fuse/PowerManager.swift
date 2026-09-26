import Foundation
import Combine
import IOKit
import IOKit.pwr_mgt
import LidGuardShared
import os

/// Manages sleep-prevention while a timer is active (feature 5).
///
/// Observes timer start (`.fuseTimerStarted`) and stop (`.fuseTimerCompleted` /
/// `.fuseTimerCancelled`).
///
/// - When `SettingsStore.shared.preventSleep` is on: holds an
///   `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, ...)`
///   for the duration, released on stop/terminate (idempotent).
/// - When `SettingsStore.shared.preventDisplaySleep` is on: additionally holds a
///   `kIOPMAssertionTypePreventUserIdleDisplaySleep` assertion so the screen stays on
///   and the fuse overlay remains visible, released on the same stop/terminate paths.
/// - When `SettingsStore.shared.keepAwakeLidClosed` is on: holds the `LidGuard` lease,
///   which the root lid-guard daemon turns into `pmset disablesleep` for as long as the
///   lease exists.
///
/// OWNER: system.
final class PowerManager {
    private let log = Logger(subsystem: logSubsystem, category: "PowerManager")

    /// Fuse 0.3 and earlier set the kernel clamshell bit directly and recorded it here.
    private static let legacyClamshellMarkerKey = "clamshellHeldByFuse"

    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false

    /// Separate assertion that also keeps the display awake (so the fuse overlay stays
    /// visible). Held independently of `assertionID`.
    private var displayAssertionID: IOPMAssertionID = 0
    private var hasDisplayAssertion = false

    private let lidGuard = LidGuard.shared
    private var settingsCancellable: AnyCancellable?

    /// Begins observing timer start/stop.
    init() {
        releaseLegacyClamshellHold()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(timerStarted), name: .fuseTimerStarted, object: nil)
        nc.addObserver(self, selector: #selector(timerStopped), name: .fuseTimerCompleted, object: nil)
        nc.addObserver(self, selector: #selector(timerStopped), name: .fuseTimerCancelled, object: nil)
        observePowerSettings()
    }

    @objc private func timerStarted() {
        reconcilePowerState()
    }

    @objc private func timerStopped() {
        releasePowerState()
    }

    /// Releases every assertion before the process exits.
    func teardownForTermination() {
        releasePowerState()
    }

    private func observePowerSettings() {
        let store = SettingsStore.shared
        settingsCancellable = Publishers.CombineLatest3(
            store.$preventSleep,
            store.$preventDisplaySleep,
            store.$keepAwakeLidClosed
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] preventSleep, preventDisplaySleep, keepAwakeLidClosed in
            self?.reconcilePowerState(
                preventSleep: preventSleep,
                preventDisplaySleep: preventDisplaySleep,
                keepAwakeLidClosed: keepAwakeLidClosed
            )
        }
    }

    private func reconcilePowerState() {
        let store = SettingsStore.shared
        reconcilePowerState(
            preventSleep: store.preventSleep,
            preventDisplaySleep: store.preventDisplaySleep,
            keepAwakeLidClosed: store.keepAwakeLidClosed
        )
    }

    private func reconcilePowerState(
        preventSleep: Bool,
        preventDisplaySleep: Bool,
        keepAwakeLidClosed: Bool
    ) {
        guard TimerEngine.shared.session != nil else {
            releasePowerState()
            return
        }

        if preventSleep {
            acquireAssertion()
        } else {
            releaseAssertion()
        }
        if preventDisplaySleep {
            acquireDisplayAssertion()
        } else {
            releaseDisplayAssertion()
        }
        if keepAwakeLidClosed {
            lidGuard.acquireLease()
        } else {
            lidGuard.releaseLease()
        }
    }

    private func releasePowerState() {
        releaseAssertion()
        releaseDisplayAssertion()
        lidGuard.releaseLease()
    }

    // MARK: - Idle-sleep assertion

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

    // MARK: - Idle-display assertion

    private func acquireDisplayAssertion() {
        guard !hasDisplayAssertion else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Fuse timer running" as CFString,
            &displayAssertionID
        )
        if result == kIOReturnSuccess {
            hasDisplayAssertion = true
        } else {
            log.error("IOPMAssertionCreateWithName (display) failed: \(result)")
        }
    }

    private func releaseDisplayAssertion() {
        guard hasDisplayAssertion else { return }
        IOPMAssertionRelease(displayAssertionID)
        hasDisplayAssertion = false
        displayAssertionID = 0
    }

    // MARK: - Legacy clamshell bit

    /// The kernel keeps the clamshell bit after its setter exits, so a pre-0.4 Fuse that
    /// died mid-timer can leave it set. Clear it once, and keep the marker for the next
    /// launch if the kernel refuses.
    private func releaseLegacyClamshellHold() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.legacyClamshellMarkerKey) else { return }
        let result = RootDomain.setClamshellSleepDisabled(false)
        if result == kIOReturnSuccess {
            defaults.removeObject(forKey: Self.legacyClamshellMarkerKey)
            log.notice("Cleared the clamshell-sleep bit left by an earlier Fuse version.")
        } else {
            log.error("Could not clear the legacy clamshell-sleep bit: \(result)")
        }
    }
}
