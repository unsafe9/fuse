import AppKit
import SwiftUI
import os

/// Owns the menu bar status item and its menu (feature 2 / 10).
final class StatusItemController: NSObject {
    private let log = Logger(subsystem: logSubsystem, category: "StatusItemController")
    private let permissions: PermissionManager

    private let statusItem: NSStatusItem
    private let menu: NSMenu

    init(permissions: PermissionManager) {
        self.permissions = permissions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        super.init()

        // Configure button
        if let button = statusItem.button {
            let image = StatusGlyph.makeImage()
            image.accessibilityDescription = "Fuse"
            button.image = image
        }

        menu.delegate = self
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(timerTick),
            name: .fuseTimerTick,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(timerChanged),
            name: .fuseTimerStarted,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(timerChanged),
            name: .fuseTimerCompleted,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(timerChanged),
            name: .fuseTimerCancelled,
            object: nil
        )
    }

    // MARK: - Button title

    @objc private func timerTick() {
        updateButtonTitle()
    }

    @objc private func timerChanged() {
        updateButtonTitle()
    }

    private func updateButtonTitle() {
        guard let button = statusItem.button else { return }
        let store = SettingsStore.shared
        if store.showRemainingInMenuBar, TimerEngine.shared.session != nil {
            let remaining = TimerEngine.shared.remaining
            let title = TimeFormat.clock(remaining)
            button.title = title
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else {
            button.title = ""
            button.font = nil
        }
    }
}

// MARK: - NSMenuDelegate

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = SettingsStore.shared
        let engine = TimerEngine.shared
        let now = Date()

        // 1. Running timer info + cancel
        if let session = engine.session {
            let remaining = engine.remaining
            let nameStr = session.name.map { "\($0) — " } ?? ""
            let infoItem = NSMenuItem(
                title: "⏳ \(nameStr)\(TimeFormat.clock(remaining)) left",
                action: nil,
                keyEquivalent: ""
            )
            infoItem.isEnabled = false
            menu.addItem(infoItem)

            let cancelItem = NSMenuItem(
                title: "Cancel Timer",
                action: #selector(cancelTimer),
                keyEquivalent: "."
            )
            cancelItem.keyEquivalentModifierMask = .command
            cancelItem.target = self
            menu.addItem(cancelItem)

            menu.addItem(.separator())
        }

        // 2. Duration presets
        if store.presetMode.showsDuration {
            for minutes in store.durationPresets {
                let label = TimeFormat.presetLabel(minutes: minutes)
                let item = NSMenuItem(title: label, action: #selector(startDurationPreset(_:)), keyEquivalent: "")
                item.tag = minutes
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // 3. Deadline presets
        if store.presetMode.showsDeadline {
            for mark in store.deadlinePresets {
                let target = DeadlineMath.nextMinuteMark(mark, after: now)
                let label = deadlineLabel(target: target)
                let item = NSMenuItem(title: label, action: #selector(startDeadlinePreset(_:)), keyEquivalent: "")
                item.tag = mark
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // 4. Custom Timer
        let customItem = NSMenuItem(title: "Custom Timer\u{2026}", action: #selector(openCustomTimer), keyEquivalent: "")
        customItem.target = self
        menu.addItem(customItem)

        menu.addItem(.separator())

        // 5. Permission warning (async refresh; show based on cached status)
        permissions.refresh { [weak self] in
            // This fires after menu is built; the next open will reflect updated status.
            _ = self
        }
        if permissions.needsAttention {
            let warnItem = NSMenuItem(
                title: "⚠ Notifications disabled \u{2014} click to fix",
                action: #selector(fixNotifications),
                keyEquivalent: ""
            )
            warnItem.target = self
            menu.addItem(warnItem)
        }

        // 6. Settings
        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        // 7. Quit
        let quitItem = NSMenuItem(title: "Quit Fuse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func cancelTimer() {
        TimerEngine.shared.cancel()
    }

    @objc private func startDurationPreset(_ sender: NSMenuItem) {
        let minutes = sender.tag
        TimerEngine.shared.start(duration: TimeInterval(minutes * 60), name: nil)
    }

    @objc private func startDeadlinePreset(_ sender: NSMenuItem) {
        // Recompute the target at click time so a menu held open across the mark
        // (e.g. sleep/wake) still starts a valid, future-dated timer.
        let mark = sender.tag
        let target = DeadlineMath.nextMinuteMark(mark, after: Date())
        TimerEngine.shared.start(until: target, name: nil)
    }

    @objc private func openCustomTimer() {
        CustomTimerPanel.shared.show()
    }

    @objc private func fixNotifications() {
        permissions.resolve()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    // MARK: - Helpers

    private func deadlineLabel(target: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeStr = formatter.string(from: target)

        // Derive the prefix from the actual target minute so the label always agrees
        // with the parenthesized time.
        let targetMinute = Calendar.current.component(.minute, from: target)
        if targetMinute == 0 {
            return "Next hour  (\(timeStr))"
        } else {
            let mins = targetMinute < 10 ? "0\(targetMinute)" : "\(targetMinute)"
            return "Next :\(mins)  (\(timeStr))"
        }
    }
}
