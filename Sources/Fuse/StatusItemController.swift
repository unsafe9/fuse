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
            // Append the round counter (#3/5) while repeating (F2).
            let roundStr = TimerSession.roundLabel(round: session.round, policy: session.repeatPolicy)
                .map { " · \($0)" } ?? ""
            let infoItem = NSMenuItem(
                title: "⏳ \(nameStr)\(TimeFormat.clock(remaining)) left\(roundStr)",
                action: nil,
                keyEquivalent: ""
            )
            infoItem.isEnabled = false
            menu.addItem(infoItem)

            let cancelItem = NSMenuItem(
                title: "Cancel Timer",
                action: #selector(cancelTimer),
                keyEquivalent: ""
            )
            cancelItem.target = self
            menu.addItem(cancelItem)

            menu.addItem(.separator())
        }

        // 1b. Idle recap + repeat last (only when no timer runs).
        if engine.session == nil {
            var addedIdleRow = false

            // Last finished timer (F5; opt-in, "N min ago" computed at open time).
            if store.showLastFinishedInMenu, let endedAt = store.lastEndedAt {
                let nameStr = store.lastEndedName.map { "\($0) · " } ?? ""
                let lastItem = NSMenuItem(
                    title: "Last: \(nameStr)ended \(lastEndedLabel(endedAt: endedAt, now: now))",
                    action: nil,
                    keyEquivalent: ""
                )
                lastItem.isEnabled = false
                menu.addItem(lastItem)
                addedIdleRow = true
            }

            // Repeat last (F4; shown whenever a previous start was recorded).
            if let expression = store.lastStartedExpression {
                let nameStr = store.lastStartedName.map { " \"\($0)\"" } ?? ""
                let againItem = NSMenuItem(
                    title: "↻ Again: \(expression)\(nameStr)",
                    action: #selector(repeatLast),
                    keyEquivalent: ""
                )
                againItem.target = self
                menu.addItem(againItem)
                addedIdleRow = true
            }

            if addedIdleRow {
                menu.addItem(.separator())
            }
        }

        // 2. Presets (one ordered list; deadline targets recomputed every open)
        for (index, expression) in store.presets.enumerated() {
            // Split off any repeat suffix (xN) so the time expression parses, then
            // reflect the policy as "×N" in the label (F1/F2).
            guard let split = try? RepeatExpression.split(expression),
                  let preset = Preset.parse(split.expression, now: now) else { continue }
            let item: NSMenuItem
            switch preset {
            case .duration(let seconds):
                item = NSMenuItem(title: PresetLabel.withRepeat(PresetLabel.duration(seconds: seconds), policy: split.policy),
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
        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: "")
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
        guard presets.indices.contains(sender.tag) else { return }
        // Route the raw expression (incl. any xN suffix) through AppController so the
        // repeat policy is applied and the last-started record is written in one place.
        // Deadline targets are recomputed inside the parser at click time, so a menu
        // held open across the mark still starts a valid, future-dated timer.
        do {
            try AppController.shared.start(expression: presets[sender.tag], name: nil)
        } catch {
            log.error("startPreset failed: \(String(describing: error), privacy: .public)")
        }
    }

    @objc private func repeatLast() {
        AppController.shared.repeatLast()
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

    /// "14:32 (8 min ago)" for the idle recap (F5). The elapsed minutes are computed at
    /// menu-open time so the label is fresh each time the menu is shown.
    private func lastEndedLabel(endedAt: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeStr = formatter.string(from: endedAt)
        let minutesAgo = max(0, Int(now.timeIntervalSince(endedAt) / 60))
        return "\(timeStr) (\(minutesAgo) min ago)"
    }
}
