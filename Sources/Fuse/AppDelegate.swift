import AppKit
import os

/// Owns the app's long-lived controllers and managers and wires them together.
///
/// All collaborators are constructed in `applicationDidFinishLaunching`. The
/// `TimerEngine` and `SettingsStore` are singletons; the controllers/managers are
/// retained here for the app's lifetime. On termination the timer is cancelled so
/// any power assertions / lid-close sleep state is always restored.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: logSubsystem, category: "AppDelegate")

    private var overlayController: OverlayController?
    private var statusItemController: StatusItemController?
    private var notificationManager: NotificationManager?
    private var permissionManager: PermissionManager?
    private var powerManager: PowerManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Eagerly realize the shared singletons.
        _ = SettingsStore.shared
        _ = TimerEngine.shared

        let permissionManager = PermissionManager()
        let notificationManager = NotificationManager(permissions: permissionManager)
        let overlayController = OverlayController()
        let powerManager = PowerManager()
        let statusItemController = StatusItemController(permissions: permissionManager)

        self.permissionManager = permissionManager
        self.notificationManager = notificationManager
        self.overlayController = overlayController
        self.powerManager = powerManager
        self.statusItemController = statusItemController

        // UNUserNotificationCenter must not be touched without a bundle (bare `swift run`).
        if Bundle.main.bundleIdentifier != nil {
            notificationManager.requestAuthorizationAtLaunch()
        } else {
            log.notice("No bundle identifier; skipping notification authorization request.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clear the lid-close sleep guard synchronously before cancel(), so the
        // clamshell bit is restored even as the process exits.
        powerManager?.teardownForTermination()
        // Release power assertions and clear the running timer on exit.
        TimerEngine.shared.cancel()
    }
}
