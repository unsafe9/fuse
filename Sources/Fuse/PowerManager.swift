import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
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
/// - When `SettingsStore.shared.keepAwakeLidClosed` is on: at timer start, disables
///   clamshell-close sleep via the `IOPMrootDomain` user client (selector
///   `kPMSetClamshellSleepState`). This needs no admin rights — the same rootless
///   mechanism Amphetamine's Closed-Display Mode uses. The kernel re-evaluates lid
///   sleep only on a transition of this bit, so enable (`1`) MUST be paired with
///   disable (`0`) on every stop path, or the Mac never sleeps on lid close again.
///   On Apple Silicon the bit can be dropped across a power-source change, so we
///   re-assert it on `IOPSNotification` and on a periodic heartbeat while active.
///
/// The clamshell bit is global, in-RAM kernel state: a reboot clears it, but it is NOT
/// auto-released when our process dies. So a crash/`SIGKILL`/deletion mid-timer could
/// otherwise leave a closed lid permanently awake. To guard against that we persist a
/// `clamshellHeldByFuse` flag while we hold the bit and reconcile on the next launch —
/// if the flag is set with no timer running, we drop the bit. (A reboot is the backstop
/// for the one case we can't reach: the app deleted while the bit is still set.)
///
/// `TimerEngine.cancel()` on app termination guarantees stop runs, so this manager
/// fully restores power state on a clean exit.
///
/// OWNER: system.
final class PowerManager {
    private let log = Logger(subsystem: logSubsystem, category: "PowerManager")

    /// `IOPMLibDefs.h`: `#define kPMSetClamshellSleepState 12`. The kernel dispatch for
    /// this selector has no entitlement/privilege check, so it works without root.
    private let clamshellSelector: UInt32 = 12

    /// UserDefaults key, persisted `true` while we hold the global clamshell-disable bit.
    /// A crash leaves it set; the next launch reconciles it (see `reconcileStaleClamshellHold`).
    private static let clamshellHeldKey = "clamshellHeldByFuse"

    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false

    /// Separate assertion that also keeps the display awake (so the fuse overlay stays
    /// visible). Held independently of `assertionID`.
    private var displayAssertionID: IOPMAssertionID = 0
    private var hasDisplayAssertion = false

    /// True while we hold the clamshell-sleep-disabled bit (paired enable/disable).
    private var lidDisableActive = false
    /// Periodic re-assert while `lidDisableActive`, in case the bit is dropped silently.
    private var lidHeartbeat: Timer?
    /// Run-loop source for power-source (AC/battery) change notifications.
    private var powerSourceSource: CFRunLoopSource?

    /// Begins observing timer start/stop and power-source notifications.
    init() {
        // Recover the global clamshell-disable bit if a previous run died without clearing
        // it — the kernel does not release it on process death.
        reconcileStaleClamshellHold()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(timerStarted), name: .fuseTimerStarted, object: nil)
        nc.addObserver(self, selector: #selector(timerStopped), name: .fuseTimerCompleted, object: nil)
        nc.addObserver(self, selector: #selector(timerStopped), name: .fuseTimerCancelled, object: nil)
        registerPowerSourceObserver()
    }

    deinit {
        if let powerSourceSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceSource, .commonModes)
        }
    }

    @objc private func timerStarted() {
        let store = SettingsStore.shared

        if store.preventSleep {
            acquireAssertion()
        }
        if store.preventDisplaySleep {
            acquireDisplayAssertion()
        }
        if store.keepAwakeLidClosed && !lidDisableActive {
            lidDisableActive = true
            // Persist the hold before flipping the bit, so a crash is always recoverable.
            UserDefaults.standard.set(true, forKey: Self.clamshellHeldKey)
            setClamshellSleepDisabled(true)
            startLidHeartbeat()
        }
    }

    @objc private func timerStopped() {
        releaseAssertion()
        releaseDisplayAssertion()
        disableLidGuard()
    }

    /// Synchronous best-effort restore for app termination. The IOKit calls are
    /// synchronous, so the clamshell bit is cleared before the process exits.
    func teardownForTermination() {
        releaseAssertion()
        releaseDisplayAssertion()
        disableLidGuard()
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

    // MARK: - Clamshell (lid-close) sleep

    private func disableLidGuard() {
        guard lidDisableActive else { return }
        lidDisableActive = false
        stopLidHeartbeat()
        setClamshellSleepDisabled(false)
        // Bit dropped — clear the persisted hold so the next launch has nothing to undo.
        UserDefaults.standard.set(false, forKey: Self.clamshellHeldKey)
    }

    /// On launch, drop a clamshell-disable bit that a previous run left set after dying
    /// without clearing it. Acts only when our own persisted flag is set — so we never
    /// stomp the bit when we weren't the one holding it — and only here at startup, where
    /// no timer can yet be keeping the Mac awake.
    private func reconcileStaleClamshellHold() {
        guard UserDefaults.standard.bool(forKey: Self.clamshellHeldKey) else { return }
        log.notice("Clearing a stale clamshell-sleep-disable hold left by a previous run.")
        setClamshellSleepDisabled(false)
        UserDefaults.standard.set(false, forKey: Self.clamshellHeldKey)
    }

    /// Toggles the `IOPMrootDomain` clamshell-sleep-disable bit. Opens, calls, and
    /// closes a fresh user client each time; synchronous and root-free.
    private func setClamshellSleepDisabled(_ disabled: Bool) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else {
            log.error("IOPMrootDomain service not found")
            return
        }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = IO_OBJECT_NULL
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard opened == kIOReturnSuccess else {
            log.error("IOServiceOpen(IOPMrootDomain) failed: \(opened)")
            return
        }
        defer { IOServiceClose(connection) }

        var input: UInt64 = disabled ? 1 : 0
        let result = IOConnectCallScalarMethod(connection, clamshellSelector, &input, 1, nil, nil)
        if result != kIOReturnSuccess {
            log.error("kPMSetClamshellSleepState(\(disabled ? 1 : 0)) failed: \(result)")
        }
    }

    // MARK: - Re-assertion (Apple Silicon power-transition robustness)

    private func startLidHeartbeat() {
        stopLidHeartbeat()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.lidDisableActive else { return }
            // Re-writing `1` when already set is a no-op; if the bit was dropped it
            // re-transitions and restores the guard.
            self.setClamshellSleepDisabled(true)
        }
        RunLoop.main.add(timer, forMode: .common)
        lidHeartbeat = timer
    }

    private func stopLidHeartbeat() {
        lidHeartbeat?.invalidate()
        lidHeartbeat = nil
    }

    private func registerPowerSourceObserver() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let manager = Unmanaged<PowerManager>.fromOpaque(ctx).takeUnretainedValue()
            guard manager.lidDisableActive else { return }
            manager.setClamshellSleepDisabled(true)
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            log.error("IOPSNotificationCreateRunLoopSource failed")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceSource = source
    }
}
