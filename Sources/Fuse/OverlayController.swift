import AppKit
import Combine
import CoreGraphics
import os

/// Draws and manages the burning-fuse overlay (feature 3, CORE).
///
/// Observes `.fuseTimerStarted` / `.fuseTimerCompleted` / `.fuseTimerCancelled`,
/// `SettingsStore` changes (color/thickness/position/display/master toggle), and
/// `NSApplication.didChangeScreenParametersNotification`. While a timer runs and the
/// overlay master toggle is on, it shows one borderless `NSWindow` per target
/// `NSScreen` (all displays, or the one matching `SettingsStore.shared.displayID`,
/// falling back to main if that display is gone).
///
/// Each overlay window MUST be configured:
/// - `level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))`
/// - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`
/// - `isOpaque = false`, `backgroundColor = .clear`, `ignoresMouseEvents = true`,
///   `hasShadow = false`, `isReleasedWhenClosed = false`
/// - frame = a strip of the configured `fuseThickness` along the configured edge of
///   `screen.frame` in global coordinates (top strip intentionally covers the menu bar).
///
/// The contained `FuseView` draws the line whose filled length is
/// `TimerEngine.shared.progress × edgeLength`, anchored at the left (horizontal) or
/// bottom (vertical), with a brighter glowing dot at the receding tip. A 1/30s
/// `Timer` in `.common` mode reads `progress` and redraws; it is invalidated when
/// the overlay is hidden. No implicit Core Animation animations.
///
/// OWNER: overlay. Compiling stub.
final class OverlayController {
    private let log = Logger(subsystem: logSubsystem, category: "OverlayController")

    /// One overlay window per target screen while visible.
    private var windows: [OverlayWindow] = []
    /// 1/30s render timer; non-nil only while the overlay is visible.
    private var renderTimer: Timer?
    private var settingsCancellable: AnyCancellable?

    /// True while the Settings "Fuse" tab requests a static preview. A real running
    /// timer always wins; preview only draws when no timer is running.
    private var previewActive = false
    /// Fixed progress drawn during preview (with the glowing tip mid-edge).
    private let previewProgress: Double = 0.7

    /// Begins observing timer + settings + screen-change notifications. The overlay
    /// only becomes visible when a timer is actually running.
    init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(timerStarted),
                       name: .fuseTimerStarted, object: nil)
        nc.addObserver(self, selector: #selector(timerStopped),
                       name: .fuseTimerCompleted, object: nil)
        nc.addObserver(self, selector: #selector(timerStopped),
                       name: .fuseTimerCancelled, object: nil)
        nc.addObserver(self, selector: #selector(previewBegan),
                       name: .fusePreviewBegan, object: nil)
        nc.addObserver(self, selector: #selector(previewEnded),
                       name: .fusePreviewEnded, object: nil)
        nc.addObserver(self, selector: #selector(screenParametersChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Live-apply color/thickness/position/display/master-toggle changes.
        // `objectWillChange` fires just *before* the new value is stored, so hop to the
        // next runloop turn to read settled values.
        settingsCancellable = SettingsStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        teardown()
    }

    // MARK: - Notification handlers

    @objc private func timerStarted() {
        refresh()
    }

    @objc private func timerStopped() {
        // A running timer always wins; once it ends, fall back to a preview if one is
        // still requested, otherwise hide.
        refresh()
    }

    @objc private func previewBegan() {
        previewActive = true
        // A running timer owns the overlay; don't disturb it. Otherwise show the preview.
        guard !isRunning else { return }
        refresh()
    }

    @objc private func previewEnded() {
        previewActive = false
        // Ending the preview must leave a running timer's overlay intact.
        guard !isRunning else { return }
        refresh()
    }

    @objc private func screenParametersChanged() {
        // Displays were added/removed/rearranged — rebuild windows for current screens.
        guard isVisible else { return }
        rebuildWindows()
    }

    private func settingsChanged() {
        // Defensively drop a stale preview if the Settings window closed without
        // posting `.fusePreviewEnded` (onDisappear can miss the window-close path).
        if previewActive && !SettingsWindowController.shared.isWindowVisible {
            previewActive = false
        }
        // Master toggle flipping or any visual setting changing while visible: re-evaluate
        // visibility, then rebuild frames/views so geometry/color/thickness apply live.
        refresh()
    }

    // MARK: - Visibility

    private var isRunning: Bool {
        TimerEngine.shared.session != nil
    }

    /// Whether the overlay should currently be on screen: a running timer or an
    /// active preview, gated by the master toggle.
    private var isVisible: Bool {
        (isRunning || previewActive) && SettingsStore.shared.overlayEnabled
    }

    /// Progress to draw: the live timer fraction while running, else the fixed preview.
    private var renderProgress: Double {
        isRunning ? TimerEngine.shared.progress : previewProgress
    }

    /// Shows or hides the overlay based on the running/preview state and the master toggle.
    private func refresh() {
        if isVisible {
            rebuildWindows()
            startRenderTimer()
        } else {
            teardown()
        }
    }

    /// Recreates one window per target screen with current settings/geometry.
    private func rebuildWindows() {
        guard SettingsStore.shared.overlayEnabled else { teardown(); return }

        teardownWindows()

        let position = SettingsStore.shared.fusePosition
        let thickness = CGFloat(SettingsStore.shared.fuseThickness)
        let color = SettingsStore.shared.fuseColor

        for screen in targetScreens() {
            let frame = stripFrame(for: screen.frame, position: position, thickness: thickness)
            let window = OverlayWindow(contentRect: frame)
            let view = FuseView(frame: NSRect(origin: .zero, size: frame.size))
            view.position = position
            view.fuseColor = color
            view.thickness = thickness
            view.update(progress: renderProgress)
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }

        startRenderTimer()
    }

    private func teardown() {
        stopRenderTimer()
        teardownWindows()
    }

    private func teardownWindows() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
    }

    // MARK: - Render timer (1/30s, only while visible)

    private func startRenderTimer() {
        guard renderTimer == nil, !windows.isEmpty else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tickRender()
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    private func stopRenderTimer() {
        renderTimer?.invalidate()
        renderTimer = nil
    }

    private func tickRender() {
        let progress = renderProgress
        for window in windows {
            (window.contentView as? FuseView)?.update(progress: progress)
        }
    }

    // MARK: - Geometry

    /// Resolves the screens to draw on: main (default), all, or a specific display.
    private func targetScreens() -> [NSScreen] {
        switch SettingsStore.shared.fuseDisplay {
        case .all:
            return NSScreen.screens
        case .main:
            return NSScreen.main.map { [$0] } ?? NSScreen.screens
        case .id(let wanted):
            if let match = NSScreen.screens.first(where: { $0.displayID == wanted }) {
                return [match]
            }
            // Configured display disconnected — fall back to main.
            if let main = NSScreen.main {
                log.notice("Configured display \(wanted) not found; falling back to main.")
                return [main]
            }
            return NSScreen.screens
        }
    }

    /// A strip of `thickness` along `position` edge of `screenFrame` (global coords).
    private func stripFrame(for screenFrame: NSRect, position: FusePosition, thickness: CGFloat) -> NSRect {
        switch position {
        case .top:
            return NSRect(x: screenFrame.minX, y: screenFrame.maxY - thickness,
                          width: screenFrame.width, height: thickness)
        case .bottom:
            return NSRect(x: screenFrame.minX, y: screenFrame.minY,
                          width: screenFrame.width, height: thickness)
        case .left:
            return NSRect(x: screenFrame.minX, y: screenFrame.minY,
                          width: thickness, height: screenFrame.height)
        case .right:
            return NSRect(x: screenFrame.maxX - thickness, y: screenFrame.minY,
                          width: thickness, height: screenFrame.height)
        }
    }
}

// MARK: - Overlay window

/// Borderless, click-through, all-Spaces window that floats above everything,
/// including fullscreen apps, per the critical config in the spec.
private final class OverlayWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: .borderless,
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension NSScreen {
    /// The `CGDirectDisplayID` backing this screen, or `0` if unavailable.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - Fuse view

/// Layer-backed view rendering the fuse line and its glowing burning tip.
///
/// Draws a filled bar of length `progress × edgeLength` from the anchored end, in
/// `SettingsStore.shared.fuseColor` at `fuseThickness`, plus a brighter/whiter glow
/// dot at the receding tip. Reads progress live from `TimerEngine.shared`. Set frames
/// directly / disable implicit actions so the 1/30s render timer is authoritative.
///
/// OWNER: overlay. Compiling stub.
final class FuseView: NSView {
    /// Edge the fuse is drawn along; controls anchoring + axis.
    var position: FusePosition = .top
    var fuseColor: NSColor = .red
    var thickness: CGFloat = 4

    private var progress: Double = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The render timer is authoritative; suppress implicit animations.
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Called by the render timer with the live progress fraction (1 → full, 0 → empty).
    func update(progress: Double) {
        let clamped = min(1, max(0, progress))
        guard clamped != self.progress else { return }
        self.progress = clamped
        needsDisplay = true
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        let horizontal = position.isHorizontal
        // Length along the burning axis; the cross-axis is `thickness`.
        let edgeLength = horizontal ? bounds.width : bounds.height
        let filled = CGFloat(progress) * edgeLength
        guard filled > 0 else { return }

        let barRect: NSRect
        // Anchor the burning end: horizontal at left, vertical at bottom; the receding
        // tip is the far end of the filled segment.
        switch position {
        case .top, .bottom:
            barRect = NSRect(x: 0, y: 0, width: filled, height: thickness)
        case .left, .right:
            barRect = NSRect(x: 0, y: 0, width: thickness, height: filled)
        }

        ctx.setFillColor(fuseColor.cgColor)
        ctx.fill(barRect)

        // Glowing burning tip at the receding end.
        let tipCenter: CGPoint
        switch position {
        case .top, .bottom:
            tipCenter = CGPoint(x: barRect.maxX, y: barRect.midY)
        case .left, .right:
            tipCenter = CGPoint(x: barRect.midX, y: barRect.maxY)
        }
        drawGlowTip(in: ctx, at: tipCenter)
    }

    /// A brighter/whiter dot with a soft glow at the receding tip.
    private func drawGlowTip(in ctx: CGContext, at center: CGPoint) {
        let radius = max(thickness * 0.9, 3)
        let dotRect = NSRect(x: center.x - radius, y: center.y - radius,
                             width: radius * 2, height: radius * 2)

        // Whiten the base color for the burning core.
        let base = fuseColor.usingColorSpace(.sRGB) ?? fuseColor
        let glowColor = NSColor(srgbRed: min(1, base.redComponent * 0.4 + 0.6),
                                green: min(1, base.greenComponent * 0.4 + 0.6),
                                blue: min(1, base.blueComponent * 0.4 + 0.6),
                                alpha: 1)

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: radius * 1.6, color: fuseColor.cgColor)
        ctx.setFillColor(glowColor.cgColor)
        ctx.fillEllipse(in: dotRect)
        ctx.restoreGState()
    }
}
