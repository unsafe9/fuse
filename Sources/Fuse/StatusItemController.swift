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

        // 2. Presets (one ordered list; deadline targets recomputed every open)
        for (index, expression) in store.presets.enumerated() {
            guard let preset = Preset.parse(expression, now: now) else { continue }
            let item: NSMenuItem
            switch preset {
            case .duration(let seconds):
                item = NSMenuItem(title: PresetLabel.duration(seconds: seconds),
                                  action: #selector(startPreset(_:)), keyEquivalent: "")
            case .mark(let minute):
                let target = DeadlineMath.nextMinuteMark(minute: minute, after: now)
                item = NSMenuItem(title: markLabel(minute: minute, target: target),
                                  action: #selector(startPreset(_:)), keyEquivalent: "")
            }
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        if !store.presets.isEmpty {
            menu.addItem(.separator())
        }

        // 3. Custom Timer
        let customItem = NSMenuItem(title: "Custom Timer\u{2026}", action: #selector(openCustomTimer), keyEquivalent: "")
        customItem.target = self
        menu.addItem(customItem)

        menu.addItem(.separator())

        // 4. Permission warning (async refresh; show based on cached status)
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

        // 5. Settings
        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        // 6. Quit
        let quitItem = NSMenuItem(title: "Quit Fuse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func cancelTimer() {
        TimerEngine.shared.cancel()
    }

    @objc private func startPreset(_ sender: NSMenuItem) {
        let presets = SettingsStore.shared.presets
        guard presets.indices.contains(sender.tag),
              let preset = Preset.parse(presets[sender.tag]) else { return }
        switch preset {
        case .duration(let seconds):
            TimerEngine.shared.start(duration: seconds, name: nil)
        case .mark(let minute):
            // Recompute the target at click time so a menu held open across the mark
            // (e.g. sleep/wake) still starts a valid, future-dated timer.
            let target = DeadlineMath.nextMinuteMark(minute: minute, after: Date())
            TimerEngine.shared.start(until: target, name: nil)
        }
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

    private func markLabel(minute: Int, target: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeStr = formatter.string(from: target)
        return "\(PresetLabel.markBase(minute: minute))  (\(timeStr))"
    }
}
