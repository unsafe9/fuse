import AppKit
import SwiftUI
import os

/// Floating panel for entering a custom timer (feature 2).
final class CustomTimerPanel: NSObject {
    private let log = Logger(subsystem: logSubsystem, category: "CustomTimerPanel")

    static let shared = CustomTimerPanel()

    private var panel: NSPanel?

    private override init() {
        super.init()
    }

    /// Shows and focuses the panel, activating the app. Idempotent.
    func show() {
        NSApp.activate(ignoringOtherApps: true)

        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let formView = CustomTimerFormView { [weak self] in
            self?.panel?.close()
            self?.panel = nil
        }

        let hosting = NSHostingController(rootView: formView)
        hosting.view.setFrameSize(hosting.view.fittingSize)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.title = "Custom Timer"
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.contentViewController = hosting
        p.isReleasedWhenClosed = false
        p.center()

        // Close button should clear our reference
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: p
        )

        panel = p
        p.makeKeyAndOrderFront(nil)
    }

    @objc private func panelWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: notification.object
        )
        panel = nil
    }
}

// MARK: - SwiftUI form

private struct CustomTimerFormView: View {
    var onClose: () -> Void

    @State private var expression: String = ""
    @State private var timerName: String = ""
    @State private var repeatEnabled: Bool = false
    @State private var repeatCount: Int = 4
    @State private var errorMessage: String = ""
    @FocusState private var expressionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Timer")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("5m, 1h30m, 90, 10:00, 23:30", text: $expression)
                    .textFieldStyle(.roundedBorder)
                    .focused($expressionFocused)
                    .onSubmit { startTimer() }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            TextField("Name (optional)", text: $timerName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { startTimer() }

            HStack {
                Toggle("Repeat", isOn: $repeatEnabled)
                Spacer()
                Stepper(value: $repeatCount, in: 2...99) {
                    Text("×\(repeatCount)")
                        .monospacedDigit()
                }
                .disabled(!repeatEnabled)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Button("Start") {
                    startTimer()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(expression.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            expressionFocused = true
        }
    }

    private func startTimer() {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let name: String? = timerName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : timerName.trimmingCharacters(in: .whitespaces)
        let fullExpression = repeatEnabled ? "\(trimmed) x\(repeatCount)" : trimmed

        do {
            try AppController.shared.start(expression: fullExpression, name: name)
        } catch let e as ParseError {
            errorMessage = e.reason
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        onClose()
    }
}
