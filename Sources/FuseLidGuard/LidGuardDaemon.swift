import Foundation
import IOKit.pwr_mgt
import LidGuardShared
import notify
import os

/// Keeps `pmset disablesleep` on exactly while a Fuse lease assertion exists.
///
/// Fuse cannot own this switch itself: it needs root and persists on disk, so a Fuse
/// crash would leave the Mac unable to sleep. The daemon follows the lease assertion
/// instead, which powerd drops when its owner exits for any reason and which times out
/// unless Fuse keeps renewing it. It re-checks when Fuse announces a lease change, and
/// on a poll that catches a lease disappearing without notice.
///
/// One instance lives for the whole process, so its handlers capture it strongly.
final class LidGuardDaemon {
    private let log = Logger(subsystem: LidGuardContract.label, category: "daemon")
    private let queue = DispatchQueue(label: "\(LidGuardContract.label).reconcile")
    private let pollInterval: DispatchTimeInterval = .seconds(15)
    private var sources: [DispatchSourceProtocol] = []
    private var notifyToken: Int32 = 0
    private var reconcileScheduled = false
    private var reportedForeignSleepDisable = false

    func run() -> Never {
        guard Installer.requireRoot() else { exit(77) }

        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { self.stop() }
            source.resume()
            sources.append(source)
        }

        notify_register_dispatch(LidGuardContract.leaseChangedNotification, &notifyToken, queue) { _ in
            self.scheduleReconcile()
        }

        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(deadline: .now(), repeating: pollInterval, leeway: .seconds(1))
        poll.setEventHandler { self.reconcile() }
        poll.resume()
        sources.append(poll)

        log.notice("Lid guard started (helper version \(LidGuardContract.helperVersion)).")
        dispatchMain()
    }

    /// Coalesces bursts of lease announcements into one check.
    private func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
            self.reconcileScheduled = false
            self.reconcile()
        }
    }

    private func reconcile() {
        let leased = Assertions.fuseLeaseIsHeld()
        let held = SleepHold.isHeld

        if leased, !held {
            if RootDomain.isSleepDisabled {
                if !reportedForeignSleepDisable {
                    log.notice("System sleep is already disabled outside Fuse; leaving it alone.")
                    reportedForeignSleepDisable = true
                }
                return
            }
            if SleepHold.take() {
                log.notice("Fuse lease started; disabled system sleep.")
            } else {
                log.error("Could not disable system sleep for the Fuse lease.")
            }
        } else if !leased, held {
            if SleepHold.release() {
                log.notice("Fuse lease ended; restored system sleep.")
            } else {
                log.error("Could not restore system sleep; will retry.")
            }
        }

        if !leased {
            reportedForeignSleepDisable = false
        }
    }

    private func stop() {
        if SleepHold.isHeld, !SleepHold.release() {
            log.error("Could not restore system sleep while stopping; the next start retries.")
        }
        log.notice("Lid guard stopped.")
        exit(0)
    }
}

enum Assertions {
    static func fuseLeaseIsHeld() -> Bool {
        all().contains { ($0["AssertName"] as? String) == LidGuardContract.leaseAssertionName }
    }

    /// powerd keeps the kernel clamshell bit set while any such assertion exists.
    static func anyAppliesOnLidClose() -> Bool {
        all().contains { ($0["AppliesOnLidClose"] as? Bool) == true }
    }

    private static func all() -> [[String: Any]] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let dict = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return []
        }
        return dict.values.flatMap { $0 }
    }
}
