import Foundation

/// Tracks Fuse's ownership of the global clamshell-sleep-disable bit.
///
/// The persisted marker is the source of truth for whether Fuse may write `0`.
/// A pending release never writes `1`, and failed releases keep exactly one
/// low-frequency retry scheduled until a later attempt succeeds.
final class ClamshellSleepController {
    enum State: Equatable {
        case inactive
        case enableRequested
        case releasePending
    }

    typealias SelectorOperation = (_ disabled: Bool) -> Bool
    typealias RetryScheduler = (@escaping () -> Void) -> () -> Void

    static let heldMarkerKey = "clamshellHeldByFuse"

    private let defaults: UserDefaults
    private let selectorOperation: SelectorOperation
    private let retryScheduler: RetryScheduler
    private var cancelReleaseRetry: (() -> Void)?

    private(set) var state: State
    var hasScheduledReleaseRetry: Bool { cancelReleaseRetry != nil }

    init(
        defaults: UserDefaults = .standard,
        selectorOperation: @escaping SelectorOperation,
        retryScheduler: @escaping RetryScheduler = ClamshellSleepController.scheduleRetry
    ) {
        self.defaults = defaults
        self.selectorOperation = selectorOperation
        self.retryScheduler = retryScheduler
        state = defaults.bool(forKey: Self.heldMarkerKey) ? .releasePending : .inactive
    }

    deinit {
        cancelScheduledReleaseRetry()
    }

    func requestEnable() {
        guard state != .enableRequested else { return }

        cancelScheduledReleaseRetry()
        state = .enableRequested
        defaults.set(true, forKey: Self.heldMarkerKey)
        _ = selectorOperation(true)
    }

    func reassertEnableIfRequested() {
        guard state == .enableRequested else { return }
        if !defaults.bool(forKey: Self.heldMarkerKey) {
            defaults.set(true, forKey: Self.heldMarkerKey)
        }
        _ = selectorOperation(true)
    }

    func requestRelease() {
        // Change state before calling the selector so callbacks can no longer
        // reassert `1`, even when this release attempt fails.
        state = .releasePending
        attemptRelease()
    }

    func recoverStaleHold() {
        requestRelease()
    }

    private func attemptRelease() {
        guard defaults.bool(forKey: Self.heldMarkerKey) else {
            cancelScheduledReleaseRetry()
            state = .inactive
            return
        }

        guard selectorOperation(false) else {
            scheduleReleaseRetryIfNeeded()
            return
        }

        defaults.set(false, forKey: Self.heldMarkerKey)
        cancelScheduledReleaseRetry()
        state = .inactive
    }

    private func scheduleReleaseRetryIfNeeded() {
        guard cancelReleaseRetry == nil else { return }
        cancelReleaseRetry = retryScheduler { [weak self] in
            guard let self else { return }
            self.cancelReleaseRetry = nil
            self.attemptRelease()
        }
    }

    private func cancelScheduledReleaseRetry() {
        cancelReleaseRetry?()
        cancelReleaseRetry = nil
    }

    private static func scheduleRetry(_ action: @escaping () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: 60, repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
