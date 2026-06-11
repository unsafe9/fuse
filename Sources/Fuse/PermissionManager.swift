import AppKit
import UserNotifications
import os

/// Tracks notification authorization status and implements the in-menu fix flow
/// (feature 10).
///
/// Caches the latest `UNAuthorizationStatus`. The status item asks `refresh(_:)`
/// when the menu opens (async, completion on main) and reads `needsAttention` to
/// decide whether to show the "⚠ Notifications disabled — click to fix" item. All
/// `UNUserNotificationCenter` access is guarded by a bundle check (bare `swift run`
/// has no bundle).
///
/// OWNER: system. Compiling stub.
final class PermissionManager {
    private let log = Logger(subsystem: logSubsystem, category: "PermissionManager")

    /// Last known status. `.notDetermined` until the first `refresh`.
    private(set) var status: UNAuthorizationStatus = .notDetermined

    init() {}

    /// True when the menu should surface the notification warning item: i.e. status
    /// is `.denied` or `.notDetermined` (and a bundle exists).
    var needsAttention: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return status == .denied || status == .notDetermined
    }

    /// Re-reads the authorization status asynchronously and calls `completion` on the
    /// main thread. No-op (reports `.notDetermined`) when there is no bundle.
    func refresh(_ completion: @escaping () -> Void) {
        guard Bundle.main.bundleIdentifier != nil else {
            completion()
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.status = settings.authorizationStatus
                completion()
            }
        }
    }

    /// Implements the warning item's click action: if `.notDetermined`, request
    /// authorization; if `.denied`, open the System Settings Notifications pane
    /// (URL "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
    /// fallback "x-apple.systempreferences:com.apple.preference.notifications").
    func resolve() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        switch status {
        case .notDetermined:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                if let error {
                    self?.log.error("Authorization request failed: \(error.localizedDescription)")
                }
                DispatchQueue.main.async {
                    self?.status = granted ? .authorized : .denied
                }
            }
        case .denied:
            let primary = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
            let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
            if NSWorkspace.shared.open(primary) == false {
                NSWorkspace.shared.open(fallback)
            }
        default:
            break
        }
    }
}
