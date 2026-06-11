import AppKit
import SwiftUI
import os

/// Manages the single Settings window (feature 1 / 5).
///
/// Wraps `SettingsView` (bound to `SettingsStore.shared`) in an `NSHostingController`
/// inside one reusable `NSWindow`. `show()` activates the app, creates the window
/// lazily on first use, brings it to front, and focuses it; reopening reuses the same
/// window rather than spawning duplicates.
final class SettingsWindowController: NSObject {
    private let log = Logger(subsystem: logSubsystem, category: "SettingsWindowController")

    /// Shared instance so the menu's "Settings…" item reuses one window.
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() {}

    /// Whether the Settings window currently exists and is on screen. Used by the
    /// overlay to defensively drop a stale preview if the window has closed.
    var isWindowVisible: Bool {
        window?.isVisible ?? false
    }

    /// Shows, orders front, and focuses the Settings window, activating the app.
    /// Idempotent.
    func show() {
        if window == nil {
            let hostingController = NSHostingController(
                rootView: SettingsView(store: SettingsStore.shared)
            )
            let win = NSWindow(contentViewController: hostingController)
            win.title = "Fuse Settings"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.center()
            window = win
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - NSWindowDelegate

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // The Fuse tab's `onDisappear` does not reliably fire when the whole window
        // closes, so end any live preview here too.
        NotificationCenter.default.post(name: .fusePreviewEnded, object: self)
    }
}
