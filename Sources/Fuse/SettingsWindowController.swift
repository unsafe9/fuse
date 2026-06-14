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
    /// Idempotent. Pass `tab` to open directly to a specific pane.
    func show(selecting tab: SettingsTab? = nil) {
        if let tab {
            SettingsNavigation.shared.selectedTab = tab
        }
        if window == nil {
            let hostingController = NSHostingController(
                rootView: SettingsView(store: SettingsStore.shared)
            )
            let win = SettingsWindow(contentViewController: hostingController)
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

// MARK: - Settings window

/// Settings window that closes on ⌘W. A menu-bar-only (`LSUIElement`) app has no
/// File ▸ Close menu item, so ⌘W is never wired to `performClose`; handle the key
/// equivalent directly instead.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
