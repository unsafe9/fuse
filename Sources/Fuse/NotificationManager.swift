import Foundation
import UserNotifications
import os

/// Wraps `UNUserNotificationCenter` for completion notifications (feature 4).
///
/// Acts as the `UNUserNotificationCenterDelegate`; `willPresent` returns
/// `[.banner, .sound]` so banners appear even when the app is active. Observes
/// `.fuseTimerCompleted`: when `SettingsStore.shared.notificationEnabled` is on it
/// delivers an immediate notification (trigger `nil`) with title = `session.name ??
/// "Fuse"`, body = `SettingsStore.shared.notificationTemplate`, and sound =
/// `.default` when `notificationSound` is on (else none). Every
/// `UNUserNotificationCenter` call is guarded by a bundle check.
///
/// Also observes `.fuseTimerStarted`/`.fuseTimerTick` to fire silent interim banners at
/// the elapsed-progress points configured by `SettingsStore.shared.milestoneSet`.
///
/// OWNER: system. Compiling stub.
final class NotificationManager: NSObject {
    private let log = Logger(subsystem: logSubsystem, category: "NotificationManager")
    private let permissions: PermissionManager

    /// Progress-milestone percentages already fired for the current round. Reset on
    /// `.fuseTimerStarted` (which fires per round, so repeats re-announce each round).
    private var firedMilestones: Set<Int> = []

    /// Begins observing the timer events and registers as the center delegate (only
    /// when a bundle is present).
    init(permissions: PermissionManager) {
        self.permissions = permissions
        super.init()

        guard Bundle.main.bundleIdentifier != nil else { return }

        UNUserNotificationCenter.current().delegate = self

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(timerStarted(_:)), name: .fuseTimerStarted, object: nil)
        center.addObserver(self, selector: #selector(timerTick(_:)), name: .fuseTimerTick, object: nil)
        center.addObserver(self, selector: #selector(timerCompleted(_:)), name: .fuseTimerCompleted, object: nil)
    }

    /// Requests `[.alert, .sound]` authorization at launch. Caller already guarantees
    /// a bundle exists. Refreshes the cached status in `permissions`.
    func requestAuthorizationAtLaunch() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                self?.log.error("Authorization failed: \(error.localizedDescription)")
            }
            self?.permissions.refresh { }
        }
    }

    /// A new round began: clear this round's milestone history so they fire afresh.
    @objc private func timerStarted(_ note: Notification) {
        firedMilestones.removeAll()
    }

    /// On each tick, fire a banner for any configured milestone the elapsed progress has
    /// just crossed. Skipped milestones (e.g. a very short timer crossing several at once)
    /// are marked fired and only the furthest one is announced.
    @objc private func timerTick(_ note: Notification) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let percents = SettingsStore.shared.milestoneSet.percents
        guard !percents.isEmpty else { return }

        let engine = TimerEngine.shared
        guard let session = engine.session else { return }

        let elapsed = (1 - engine.progress) * 100
        let crossed = percents.filter { !firedMilestones.contains($0) && elapsed >= Double($0) }
        guard let furthest = crossed.max() else { return }
        firedMilestones.formUnion(crossed)

        let content = UNMutableNotificationContent()
        content.title = session.name ?? "Fuse"
        let label = furthest == 50 ? "Halfway" : "\(furthest)%"
        content.body = "\(label) · \(TimeFormat.clock(engine.remaining)) left"
        deliver(content, idPrefix: "fuse.milestone")
    }

    @objc private func timerCompleted(_ note: Notification) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let store = SettingsStore.shared
        guard store.notificationEnabled else { return }

        let session = note.userInfo?[fuseSessionKey] as? TimerSession

        let content = UNMutableNotificationContent()
        content.title = session?.name ?? "Fuse"
        content.body = store.notificationTemplate
        if store.notificationSound {
            content.sound = .default
        }
        deliver(content, idPrefix: "fuse.completion")
    }

    /// Posts an immediate (trigger `nil`) notification, logging any delivery failure.
    private func deliver(_ content: UNNotificationContent, idPrefix: String) {
        let request = UNNotificationRequest(
            identifier: "\(idPrefix).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.log.error("Failed to deliver notification: \(error.localizedDescription)")
            } else {
                self?.log.debug("Delivered \(idPrefix): \(content.body)")
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
