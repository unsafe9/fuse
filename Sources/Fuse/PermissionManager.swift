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
    /// authorization; if `.denied`, deep-link System Settings straight to Fuse's own row
    /// in the Notifications pane so the user can flip "Allow Notifications" back on. The
    /// per-app form appends `?id=<bundle id>` to the Notifications extension URL; it only
    /// works through `NSWorkspace.open` (not the `open` CLI). Falls back to the general
    /// Notifications pane, then the legacy pane id, if the per-app form is rejected.
    func resolve() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
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
            let perApp = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")!
            let pane = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
            let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
            if !NSWorkspace.shared.open(perApp), !NSWorkspace.shared.open(pane) {
                NSWorkspace.shared.open(legacy)
            }
        default:
            break
        }
    }
}
