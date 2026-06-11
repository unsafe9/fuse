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
/// OWNER: system. Compiling stub.
final class NotificationManager: NSObject {
    private let log = Logger(subsystem: logSubsystem, category: "NotificationManager")
    private let permissions: PermissionManager

    /// Begins observing `.fuseTimerCompleted` and registers as the center delegate
    /// (only when a bundle is present).
    init(permissions: PermissionManager) {
        self.permissions = permissions
        super.init()

        guard Bundle.main.bundleIdentifier != nil else { return }

        UNUserNotificationCenter.current().delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(timerCompleted(_:)),
            name: .fuseTimerCompleted,
            object: nil
        )
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

        let request = UNNotificationRequest(
            identifier: "fuse.completion.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.log.error("Failed to deliver notification: \(error.localizedDescription)")
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
