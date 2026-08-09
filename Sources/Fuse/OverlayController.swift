import AppKit
import Combine
import CoreGraphics
import os

/// Shared device RGB color space for all offscreen bakes/gradients (immutable, reusable).
private let deviceRGB = CGColorSpaceCreateDeviceRGB()

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
/// The contained `FuseView` renders the line whose filled length is derived from
/// `TimerEngine.shared.progress` and the selected progress mode, as a Core Animation
/// layer tree anchored at the left (horizontal) or bottom (vertical), with a brighter
/// glowing tip at the active end. There is no per-frame CPU render loop: per-frame
/// compositing is the GPU's job, and the controller only does light work on the engine's 0.25s
/// `.fuseTimerTick` — pushing the new progress/remaining into each view (animated over
/// 0.25s) and running the hover-tooltip hit test.
///
/// OWNER: overlay. Compiling stub.
final class OverlayController {
    private let log = Logger(subsystem: logSubsystem, category: "OverlayController")

    /// One overlay window per target screen while visible.
    private var windows: [OverlayWindow] = []
    private var hoverTooltip: FuseHoverTooltipWindow?
    private var settingsCancellable: AnyCancellable?

    /// True while the Settings "Fuse" tab requests a static preview. A real running
    /// timer always wins; preview only draws when no timer is running.
    private var previewActive = false
    /// Fixed visible length drawn during preview (with the glowing tip mid-edge).
    private let previewVisibleProgress: Double = 0.7

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
        nc.addObserver(self, selector: #selector(timerTicked),
                       name: .fuseTimerTick, object: nil)
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

    /// The engine's 0.25s tick: while visible & running, push the new progress/remaining
    /// into each view (animated over 0.25s so the bar/tip glide between ticks) and run the
    /// hover-tooltip hit test. This replaces the old 1/30s CPU render loop — flicker/spark
    /// run as GPU-side CA animations, so this is the only per-tick app work.
    @objc private func timerTicked() {
        guard isVisible, isRunning else { return }
        let progress = TimerEngine.shared.progress
        let remaining = TimerEngine.shared.remaining
        for window in windows {
            (window.contentView as? FuseView)?.tick(progress: progress, remaining: remaining)
        }

        let mouseLocation = NSEvent.mouseLocation
        let hoveringFuse = windows.contains { window in
            guard let view = window.contentView as? FuseView else { return false }
            return view.containsVisibleFuse(at: mouseLocation, in: window)
        }
        if let session = TimerEngine.shared.session, hoveringFuse {
            showHoverTooltip(session: session, remaining: remaining, at: mouseLocation)
        } else {
            hideHoverTooltip()
        }
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

    /// Engine progress to draw: the live timer fraction while running, else a fixed
    /// preview value chosen to keep the visible length consistent across modes.
    private var renderProgress: Double {
        if isRunning { return TimerEngine.shared.progress }
        switch SettingsStore.shared.fuseProgressMode {
        case .burnDown:
            return previewVisibleProgress
        case .buildUp:
            return 1 - previewVisibleProgress
        }
    }

    /// Shows or hides the overlay based on the running/preview state and the master toggle.
    private func refresh() {
        if isVisible {
            rebuildWindows()
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
        let texture = SettingsStore.shared.fuseTexture
        let tipEffect = SettingsStore.shared.fuseTipEffect
        let tipScale = CGFloat(SettingsStore.shared.fuseTipScale)
        let progressMode = SettingsStore.shared.fuseProgressMode
        let flareIntensifyEnabled = SettingsStore.shared.flareIntensifyEnabled
        let flareEnlargeScale = CGFloat(SettingsStore.shared.flareEnlargeScale)
        let flareColor = SettingsStore.shared.flareColor
        // Notch handling only applies to the top edge; off-edge it's a no-op.
        let notch = position == .top ? SettingsStore.shared.notchHandling : .over
        // Below-notch drops the strip into the menu-bar area, where (unlike the top-edge
        // case) the tip's upward spill is on screen. Add headroom above the line so it
        // isn't clipped at the strip's top edge.
        let topHeadroom = notch == .below ? FuseMetrics.tipPadding(thickness: thickness, scale: tipScale) : 0

        for screen in targetScreens() {
            let gap = notch == .skip ? notchGap(for: screen) : nil
            let frame = stripFrame(for: screen, position: position, thickness: thickness, scale: tipScale, belowNotch: notch == .below, topHeadroom: topHeadroom)
            let window = OverlayWindow(contentRect: frame)
            let view = FuseView(frame: NSRect(origin: .zero, size: frame.size))
            view.position = position
            view.fuseColor = color
            view.thickness = thickness
            view.texture = texture
            view.tipEffect = tipEffect
            view.tipScale = tipScale
            view.progressMode = progressMode
            view.flareIntensifyEnabled = flareIntensifyEnabled
            view.flareEnlargeScale = flareEnlargeScale
            view.flareColor = flareColor
            view.flareLeadSeconds = SettingsStore.flareLeadSeconds
            view.notchGap = gap
            view.topHeadroom = topHeadroom
            view.setProgress(renderProgress)
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    private func teardown() {
        hideHoverTooltip()
        teardownWindows()
    }

    private func teardownWindows() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
    }

    // MARK: - Hover tooltip

    private func showHoverTooltip(session: TimerSession, remaining: TimeInterval, at point: NSPoint) {
        let tooltip = hoverTooltip ?? FuseHoverTooltipWindow()
        hoverTooltip = tooltip
        tooltip.show(session: session, remaining: remaining, at: point)
    }

    private func hideHoverTooltip() {
        hoverTooltip?.hide()
    }

    // MARK: - Geometry

    /// Resolves the screens to draw on: main (default), all, or a specific display.
    private func targetScreens() -> [NSScreen] {
        switch SettingsStore.shared.fuseDisplay {
        case .all:
            return NSScreen.screens
        case .main:
            return primaryScreen().map { [$0] } ?? NSScreen.screens
        case .id(let wanted):
            if let match = NSScreen.screens.first(where: { $0.displayID == wanted }) {
                return [match]
            }
            // Configured display disconnected — fall back to the primary display.
            if let primary = primaryScreen() {
                log.notice("Configured display \(wanted) not found; falling back to primary.")
                return [primary]
            }
            return NSScreen.screens
        }
    }

    /// The primary display (the one hosting the menu bar), resolved via `CGMainDisplayID`.
    /// Unlike `NSScreen.main` — which tracks the key-window screen and, for a menu-bar-only
    /// app with no key window, can shift between auto-repeat rounds — this stays fixed, so a
    /// repeating timer's overlay reappears on the same display every round.
    private func primaryScreen() -> NSScreen? {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.first { $0.displayID == mainID } ?? NSScreen.main
    }

    /// The notch's horizontal gap on `screen`, in the overlay's burn-axis local x
    /// (0 = left screen edge): `start` is where the camera housing begins, `width` its
    /// extent. Returns nil on a display without a notch. Used by the "skip the notch"
    /// top mode so the fuse jumps across the housing instead of hiding behind it.
    private func notchGap(for screen: NSScreen) -> (start: CGFloat, width: CGFloat)? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        let start = left.maxX - screen.frame.minX
        let width = right.minX - left.maxX
        guard width > 0 else { return nil }
        return (start, width)
    }

    /// A strip along `position` edge of the screen (global coords). The line itself is
    /// `thickness`, but the strip is widened on its interior side by `tipPadding` so the
    /// burning tip can bulge a bit past the line without being clipped. When `belowNotch`
    /// is set, the top strip is dropped by the screen's top safe-area inset so a notched
    /// MacBook draws the line just under the notch (0 inset elsewhere leaves it unchanged).
    /// `topHeadroom` extends the top strip *above* the line (the below-notch case) so the
    /// tip's upward spill into the menu-bar area isn't clipped; `FuseView.topHeadroom`
    /// pushes the line down to match.
    private func stripFrame(for screen: NSScreen, position: FusePosition, thickness: CGFloat, scale: CGFloat, belowNotch: Bool, topHeadroom: CGFloat) -> NSRect {
        let screenFrame = screen.frame
        let band = thickness + FuseMetrics.tipPadding(thickness: thickness, scale: scale)
        switch position {
        case .top:
            let inset = belowNotch ? screen.safeAreaInsets.top : 0
            return NSRect(x: screenFrame.minX, y: screenFrame.maxY - inset - band,
                          width: screenFrame.width, height: band + topHeadroom)
        case .bottom:
            return NSRect(x: screenFrame.minX, y: screenFrame.minY,
                          width: screenFrame.width, height: band)
        case .left:
            return NSRect(x: screenFrame.minX, y: screenFrame.minY,
                          width: band, height: screenFrame.height)
        case .right:
            return NSRect(x: screenFrame.maxX - band, y: screenFrame.minY,
                          width: band, height: screenFrame.height)
        }
    }
}

// MARK: - Shared metrics

/// Geometry shared between the overlay window (how tall to make the strip) and the
/// `FuseView` (how big to draw the tip), so the two always agree.
private enum FuseMetrics {
    /// Extra cross-axis headroom, in points, added on the strip's interior side so the
    /// burning tip can spill a little past the line's configured thickness. Scales with
    /// the chosen tip size so a bigger tip gets proportionally more room.
    static func tipPadding(thickness: CGFloat, scale: CGFloat) -> CGFloat {
        max(thickness * 1.4, 12) * scale
    }
}

// MARK: - ETA formatting

/// Formats a wall-clock instant for the hover ETA (F3), following the user's locale
/// 12/24-hour preference via `DateFormatter`'s `.short` time style.
private enum ETAFormat {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func shortTime(_ date: Date) -> String {
        formatter.string(from: date)
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

private final class FuseHoverTooltipWindow: NSWindow {
    private let tooltipView = FuseHoverTooltipView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        isReleasedWhenClosed = false
        contentView = tooltipView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(session: TimerSession, remaining: TimeInterval, at point: NSPoint) {
        let trimmedName = session.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = trimmedName.flatMap { $0.isEmpty ? nil : $0 } ?? "Timer"
        // F2: append the round count on the name line while repeating ("focus  #3/5").
        if let round = TimerSession.roundLabel(round: session.round, policy: session.repeatPolicy) {
            name += "  \(round)"
        }
        tooltipView.update(name: name, remaining: TimeFormat.clock(remaining), detail: detail(for: session))
        let size = tooltipView.preferredSize
        setContentSize(size)
        setFrameOrigin(origin(near: point, size: size))
        orderFrontRegardless()
    }

    /// Builds the secondary detail line: the end-time ETA (F3-C1) and, while repeating,
    /// the relay's final ETA (F3-C2). Returns `nil` when the end-time setting is off and
    /// there is nothing to add.
    private func detail(for session: TimerSession) -> String? {
        guard SettingsStore.shared.showEndTimeInTooltip else { return nil }
        var parts = ["ends \(ETAFormat.shortTime(session.endDate))"]
        if let finish = session.relayFinish() {
            parts.append("all done ~\(ETAFormat.shortTime(finish))")
        }
        return parts.joined(separator: " · ")
    }

    func hide() {
        orderOut(nil)
    }

    private func origin(near point: NSPoint, size: NSSize) -> NSPoint {
        let screenFrame = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 8
        var x = point.x + 12
        var y = point.y - size.height - 12

        if y < screenFrame.minY + margin {
            y = point.y + 16
        }

        x = min(max(x, screenFrame.minX + margin), screenFrame.maxX - size.width - margin)
        y = min(max(y, screenFrame.minY + margin), screenFrame.maxY - size.height - margin)
        return NSPoint(x: x, y: y)
    }
}

private final class FuseHoverTooltipView: NSView {
    private var name = "Timer"
    private var remaining = "0:00"
    /// Secondary info appended after "X left" (F3 ETA / relay ETA), or nil.
    private var detail: String?
    private let maxTextWidth: CGFloat = 240
    private let padding = NSEdgeInsets(top: 7, left: 10, bottom: 8, right: 10)
    private let lineGap: CGFloat = 2

    var preferredSize: NSSize {
        let nameSize = (name as NSString).size(withAttributes: nameAttributes)
        let remainingSize = (remainingText as NSString).size(withAttributes: remainingAttributes)
        let width = min(maxTextWidth, max(nameSize.width, remainingSize.width))
            + padding.left + padding.right
        let height = nameSize.height + lineGap + remainingSize.height + padding.top + padding.bottom
        return NSSize(width: ceil(width), height: ceil(height))
    }

    private var remainingText: String {
        guard let detail, !detail.isEmpty else { return "\(remaining) left" }
        return "\(remaining) left · \(detail)"
    }

    override var isFlipped: Bool { true }

    func update(name: String, remaining: String, detail: String?) {
        self.name = name
        self.remaining = remaining
        self.detail = detail
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.78).setFill()
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        background.fill()

        NSColor.white.withAlphaComponent(0.14).setStroke()
        background.lineWidth = 1
        background.stroke()

        let textWidth = bounds.width - padding.left - padding.right
        let nameSize = (name as NSString).size(withAttributes: nameAttributes)
        let nameRect = NSRect(x: padding.left, y: padding.top,
                              width: textWidth, height: ceil(nameSize.height))
        let remainingRect = NSRect(x: padding.left, y: nameRect.maxY + lineGap,
                                   width: textWidth, height: ceil((remainingText as NSString).size(withAttributes: remainingAttributes).height))

        (name as NSString).draw(with: nameRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: nameAttributes)
        (remainingText as NSString).draw(with: remainingRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                         attributes: remainingAttributes)
    }

    private var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }

    private var nameAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]
    }

    private var remainingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.78),
            .paragraphStyle: paragraphStyle
        ]
    }
}

private extension NSScreen {
    /// The `CGDirectDisplayID` backing this screen, or `0` if unavailable.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - Fuse view

/// Layer-backed view rendering the fuse line, its chosen texture, and its burning tip as
/// a Core Animation layer tree (GPU-composited).
///
/// A filled bar of length `progress × edgeLength` is masked out of a once-baked texture
/// image, ending in the selected `FuseTipEffect` (glow / flame / sparks). All layers are
/// built in a local space where +x is the burn direction and +y points toward the screen
/// interior; a single 4-edge `CGAffineTransform` on the root container maps that space to
/// each of top/bottom/left/right, so one code path serves all four edges. The texture
/// only shades the `thickness` bar; the tip is allowed to bulge a little past the line
/// into the strip's interior `FuseMetrics.tipPadding` headroom.
///
/// There is NO per-frame `draw(_:)`. The texture bar and tip/flare sprites are baked into
/// `CGImage`s once (and re-baked only when color/thickness/texture/effect/edge-length or
/// the backing scale change). Progress changes glide the progress mask + tip position via
/// 0.25s `CABasicAnimation`s on the engine tick; flicker/spark run as infinite GPU-side
/// CA animations (zero CPU); flare opacity/scale update on the tick.
///
/// OWNER: overlay.
final class FuseView: NSView {
    /// Edge the fuse is drawn along; controls anchoring + axis.
    var position: FusePosition = .top
    var fuseColor: NSColor = .red
    var thickness: CGFloat = 4
    var texture: FuseTexture = .rope
    var tipEffect: FuseTipEffect = .flame
    var tipScale: CGFloat = 1
    /// Whether the visible fuse length burns down or builds up toward the deadline.
    var progressMode: FuseProgressMode = .burnDown
    /// Flare (F6): master — shift the fuse toward `flareColor` near the end.
    var flareIntensifyEnabled = false
    /// Flare (F6): how much the flame/tip grows near the end, as a multiplier
    /// (1× = no growth). Sub-option of intensify.
    var flareEnlargeScale: CGFloat = 2
    var flareColor: NSColor = .orange
    /// Seconds before the end at which flare ramps in (clamped to `total/2`).
    var flareLeadSeconds: TimeInterval = 30
    /// When skipping the notch (top mode, notched display): the camera-housing gap in
    /// burn-axis local x (`start` = gap left edge, `width` = its extent). The fuse fills
    /// up to the gap, jumps it, and continues past it. nil = draw one continuous line.
    var notchGap: (start: CGFloat, width: CGFloat)?
    /// Extra strip headroom above the line (below-notch top mode). The line is pushed down
    /// by this much so the burning tip's upward spill renders into the menu-bar area
    /// instead of being clipped at the strip's top edge. 0 in every other case.
    var topHeadroom: CGFloat = 0

    private var progress: Double = 1
    /// Remaining seconds, fed by the tick; drives the flare ramp. Starts at `.infinity`
    /// so flare never fires before the first tick (and during preview).
    private var remaining: TimeInterval = .infinity

    /// Duration of the progress/tip glide between 0.25s engine ticks.
    private let tickDuration: CFTimeInterval = 0.25

    // MARK: - Layer tree

    /// Root container carrying the 4-edge affine transform; all sublayers live in burn-axis
    /// local coords. Built lazily once attached to a window (so the backing scale is known).
    private var root: CALayer?
    /// The baked full-length `flareColor` texture, crossfaded over the base line near the
    /// end (F6). Only built when flare is enabled; nil otherwise.
    private var flareLineLayer: CALayer?
    /// Rectangular alpha mask whose width = filled length (one piece, or two around a notch).
    private var progressMask: CALayer?
    /// Far-side mask piece for the notch `skip` case (nil otherwise).
    private var progressMaskFar: CALayer?
    /// Moves with the receding tip; carries the per-tick flare enlarge scale. Holds the tip
    /// and flare sprites as siblings so they enlarge together while their transforms stay
    /// independent of the tip's flicker keyframe.
    private var tipHolder: CALayer?
    /// `flareColor` flame sprite crossfaded over the tip near the end. Only built when flare
    /// is enabled; nil otherwise.
    private var flareLayer: CALayer?
    /// GPU ember particles (spark effect only).
    private var sparkEmitter: CAEmitterLayer?
    /// Backing scale the current images were baked at, or nil before the first bake. Lets
    /// `viewDidChangeBackingProperties` skip a redundant full re-bake when the scale is
    /// unchanged (it fires alongside `viewDidMoveToWindow` on the initial attach).
    private var bakedScale: CGFloat?

    /// Edge length along the burn axis (the strip's long side).
    private var edgeLength: CGFloat {
        position.isHorizontal ? bounds.width : bounds.height
    }

    /// Usable burn length: the notch `skip` case removes the gap so the pace stays constant.
    private var effectiveLength: CGFloat {
        notchGap.map { edgeLength - $0.width } ?? edgeLength
    }

    /// Visible filled fraction. `progress` itself remains the engine's remaining fraction,
    /// because flare timing reconstructs total duration from `remaining / progress`.
    private var visualProgress: CGFloat {
        let remainingFraction = CGFloat(min(1, max(0, progress)))
        switch progressMode {
        case .burnDown:
            return remainingFraction
        case .buildUp:
            return 1 - remainingFraction
        }
    }

    /// 0 outside the flare window, ramping 0→1 over the last `lead` seconds. The lead is
    /// clamped to `total/2` so a short timer doesn't sit flared from the start. Returns 0
    /// when flare is off.
    ///
    /// `total` is reconstructed from `remaining / progress` (since the engine's progress
    /// is `remaining / total`), which the view doesn't carry directly.
    private var flareFraction: CGFloat {
        guard flareIntensifyEnabled else { return 0 }
        guard remaining.isFinite, remaining > 0, progress > 0 else { return 0 }
        let total = remaining / progress
        let lead = min(flareLeadSeconds, total / 2)
        guard lead > 0, remaining <= lead else { return 0 }
        return CGFloat(min(1, max(0, (lead - remaining) / lead)))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Backing / lifecycle

    override var isFlipped: Bool { false }

    /// Build once we know which window (and backing scale) we are attached to. This and
    /// `viewDidChangeBackingProperties` both fire on the initial attach; the guard makes the
    /// pair idempotent so the full-edge bitmaps bake only once (skip when the tree already
    /// exists at the current scale).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildLayersIfNeeded()
    }

    /// Re-bake the images when the backing scale changes (e.g. moved to a Retina display).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildLayersIfNeeded()
    }

    /// Builds the layer tree on first attach and re-bakes only when the backing scale
    /// actually changed, so the two lifecycle callbacks don't bake the bitmaps twice.
    private func rebuildLayersIfNeeded() {
        guard window != nil else { return }
        if root != nil && bakedScale == backingScale { return }
        rebuildLayers()
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? layer?.contentsScale ?? 2
    }

    // MARK: - Public API

    /// Sets the progress immediately (no animation): initial draw / rebuild / preview.
    func setProgress(_ progress: Double) {
        self.progress = min(1, max(0, progress))
        applyProgress(animated: false)
    }

    /// Called by the engine's 0.25s tick: store progress/remaining, glide the mask/tip to
    /// the new values (0.25s linear), and refresh the flare crossfade. Flicker/spark are
    /// already running as infinite GPU animations, so nothing per-frame happens here.
    func tick(progress: Double, remaining: TimeInterval) {
        self.progress = min(1, max(0, progress))
        self.remaining = remaining
        applyProgress(animated: true)
        applyFlare()
    }

    func containsVisibleFuse(at screenPoint: NSPoint, in window: NSWindow) -> Bool {
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = convert(windowPoint, from: nil)
        guard bounds.contains(viewPoint) else { return false }

        let edgeLength = position.isHorizontal ? bounds.width : bounds.height
        let pad = FuseMetrics.tipPadding(thickness: thickness, scale: tipScale)
        let point = drawingPoint(from: viewPoint)
        guard point.x >= 0, point.y >= 0, point.y <= thickness + pad else { return false }

        if let gap = notchGap {
            let filled = visualProgress * (edgeLength - gap.width)
            guard filled > 0 else { return false }
            if point.x <= gap.start { return point.x <= filled + pad }
            if point.x < gap.start + gap.width { return false }  // inside the notch gap
            return point.x - gap.width <= filled + pad           // far side: map out the gap
        }

        let filled = visualProgress * edgeLength
        guard filled > 0 else { return false }
        return point.x <= min(edgeLength, filled + pad)
    }

    private func drawingPoint(from viewPoint: NSPoint) -> NSPoint {
        switch position {
        case .top:
            return NSPoint(x: viewPoint.x, y: bounds.height - topHeadroom - viewPoint.y)
        case .bottom:
            return viewPoint
        case .left:
            return NSPoint(x: viewPoint.y, y: viewPoint.x)
        case .right:
            return NSPoint(x: viewPoint.y, y: bounds.width - viewPoint.x)
        }
    }

    // MARK: - Layer tree assembly

    /// (Re)builds the whole layer tree: bakes the texture/tip/flare sprites at the current
    /// backing scale, wires up the mask, attaches the infinite flicker/spark animations, and
    /// applies the current progress. Called on attach, backing-scale change, or settings
    /// change (via `OverlayController.rebuildWindows`, which makes a fresh view).
    private func rebuildLayers() {
        guard let host = layer, edgeLength > 0, thickness > 0 else { return }
        let scale = backingScale
        bakedScale = scale

        withoutAnimations {
            // Tear down any previous tree (backing-scale change reuses the same view).
            root?.removeFromSuperlayer()
            let container = CALayer()
            container.frame = bounds
            container.anchorPoint = CGPoint(x: 0, y: 0)
            container.position = CGPoint(x: 0, y: 0)
            container.masksToBounds = false
            // The root carries the 4-edge mapping; with anchor+position at the origin,
            // `setAffineTransform(t)` reproduces the old `ctx.concatenate(t)` 1:1.
            container.setAffineTransform(edgeTransform())
            host.addSublayer(container)
            root = container

            buildLineLayer(scale: scale, into: container)
            buildTipLayers(scale: scale, into: container)
            if tipEffect == .spark { buildSparkEmitter(scale: scale, into: container) }

            applyProgress(animated: false)
            applyFlare()
        }
    }

    /// The burn-axis-local → view transform for each edge (mirrors the old `draw` switch).
    private func edgeTransform() -> CGAffineTransform {
        switch position {
        case .top:
            return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height - topHeadroom)
        case .bottom:
            return .identity
        case .left:
            return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .right:
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: bounds.width, ty: 0)
        }
    }

    /// Bakes the base + flare texture bars once and wraps them in a container that carries
    /// the shared width-driven progress mask. The flare layer crossfades over the base near
    /// the end (F6) so the whole filled line tints toward `flareColor`, not just the tip.
    private func buildLineLayer(scale: CGFloat, into container: CALayer) {
        // A container so both texture layers share ONE progress mask (revealing the same
        // filled length) and crossfade independently via opacity.
        let lineBox = CALayer()
        lineBox.anchorPoint = CGPoint(x: 0, y: 0)
        lineBox.position = CGPoint(x: 0, y: 0)
        lineBox.bounds = CGRect(x: 0, y: 0, width: edgeLength, height: thickness)
        container.addSublayer(lineBox)

        // The base bar is baked across the FULL edge length (not effectiveLength) so the
        // far-of-notch stretch still has texture content out to the screen edge.
        let line = CALayer()
        line.anchorPoint = CGPoint(x: 0, y: 0)
        line.position = CGPoint(x: 0, y: 0)
        line.bounds = lineBox.bounds
        line.contentsScale = scale
        line.contents = bakeTexture(length: edgeLength, cross: thickness, color: fuseColor, scale: scale)
        lineBox.addSublayer(line)

        // The `flareColor` bar crossfades over the base near the end. Only bake/add it when
        // flare is enabled — otherwise this full-edge bitmap would be wasted every rebuild.
        if flareIntensifyEnabled {
            let flareLine = CALayer()
            flareLine.anchorPoint = CGPoint(x: 0, y: 0)
            flareLine.position = CGPoint(x: 0, y: 0)
            flareLine.bounds = lineBox.bounds
            flareLine.contentsScale = scale
            flareLine.contents = bakeTexture(length: edgeLength, cross: thickness, color: flareColor, scale: scale)
            flareLine.opacity = 0
            lineBox.addSublayer(flareLine)
            flareLineLayer = flareLine
        } else {
            flareLineLayer = nil
        }

        // The mask reveals 0…filled of the container (both bars) by alpha. An opaque black
        // rectangle of the right width is enough — only its alpha coverage matters.
        let mask = CALayer()
        mask.anchorPoint = CGPoint(x: 0, y: 0)
        mask.position = CGPoint(x: 0, y: 0)
        mask.backgroundColor = NSColor.black.cgColor
        lineBox.mask = mask
        progressMask = mask

        // Notch `skip`: a second mask piece on the far side of the gap exposes the texture
        // stretch past the housing; the main mask covers only up to the gap.
        if notchGap != nil {
            let far = CALayer()
            far.anchorPoint = CGPoint(x: 0, y: 0)
            far.position = CGPoint(x: 0, y: 0)
            far.backgroundColor = NSColor.black.cgColor
            mask.addSublayer(far)
            progressMaskFar = far
        } else {
            progressMaskFar = nil
        }
    }

    /// Bakes the static tip sprite (glow/flame) and the flare sprite once, then nests both
    /// inside a holder centered on the burn point. The holder moves with progress and
    /// carries the flare enlarge scale; the tip sprite separately carries the infinite
    /// flicker keyframe, so the two transforms compose without fighting over `transform`.
    private func buildTipLayers(scale: CGFloat, into container: CALayer) {
        // The sprite square must hold the baseline flame/glow extent plus its blur. The
        // flicker/flare runtime scale-ups (≤ ~1.15× and the enlarge multiplier) grow the
        // already-baked sprite — acceptable softening, no extra bitmap room needed.
        let pad = FuseMetrics.tipPadding(thickness: thickness, scale: tipScale)
        let glowReach = max(thickness * 0.9, 3) * tipScale * 2.6   // glow blur ≈ radius·1.6
        let flameReach = (thickness / 2 + pad * 0.85) * 1.45        // flame body·core scaleX
        // Sprite half-extent: square of side 2·extent, its center mapping to the burn point.
        let tipExtent = ceil(max(glowReach, flameReach, thickness)) + 2
        let side = tipExtent * 2

        // A zero-size holder pinned to the burn point; sprites center on it via their own
        // anchorPoint (0.5, 0.5) at the holder's local origin.
        let holder = CALayer()
        holder.bounds = .zero
        container.addSublayer(holder)
        tipHolder = holder

        if progressMode == .buildUp {
            let trailWidth = tipExtent * 3
            let charge = CALayer()
            charge.bounds = CGRect(x: 0, y: 0, width: trailWidth, height: side)
            charge.anchorPoint = CGPoint(x: 1, y: 0.5)
            charge.position = .zero
            charge.contentsScale = scale
            charge.contents = bakeBuildUpChargeTrail(width: trailWidth, height: side, scale: scale)
            charge.opacity = 0.55
            holder.addSublayer(charge)
            attachBuildUpPulse(to: charge)
        }

        let tip = CALayer()
        tip.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        tip.position = .zero
        tip.contentsScale = scale
        tip.contents = bakeTip(extent: tipExtent, scale: scale)
        holder.addSublayer(tip)

        // The `flareColor` flame crossfades over the tip near the end. Only bake/add it when
        // flare is enabled — otherwise this tip sprite would be wasted every rebuild.
        if flareIntensifyEnabled {
            let flare = CALayer()
            flare.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            flare.position = .zero
            flare.contentsScale = scale
            flare.contents = bakeFlareTip(extent: tipExtent, scale: scale)
            flare.opacity = 0
            holder.addSublayer(flare)
            flareLayer = flare
        } else {
            flareLayer = nil
        }

        if tipEffect.isAnimated {
            attachFlicker(to: tip)
        }
    }

    /// An infinite, GPU-driven flicker on the tip's scale, sampled from the same multi-sine
    /// curve the old per-frame `flicker()` used (baseline `intensify = 0`). The window is
    /// closed back to its first value so the looping keyframe has no positional jump at the
    /// seam (the two sines don't share an integer period, so an exact loop isn't possible —
    /// only the tiny slope change at the seam remains, imperceptible at this amplitude).
    private func attachFlicker(to layer: CALayer) {
        let steps = 120
        var values: [CGFloat] = (0..<steps).map { flicker(phase: $0) }
        values.append(values[0])
        let anim = CAKeyframeAnimation(keyPath: "transform.scale")
        anim.values = values
        anim.duration = Double(steps) / 30.0   // matches the old 30fps phase advance
        anim.repeatCount = .infinity
        anim.calculationMode = .linear
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "flicker")
    }

    /// Build-up mode uses a slow additive pulse behind the leading tip, like pressure
    /// charging along the newly drawn fuse.
    private func attachBuildUpPulse(to layer: CALayer) {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0.35, 0.85, 0.55, 0.75, 0.35]
        anim.keyTimes = [0, 0.25, 0.55, 0.78, 1]
        anim.duration = 1.2
        anim.repeatCount = .infinity
        anim.calculationMode = .linear
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "buildUpPulse")
    }

    /// GPU ember particles approximating `drawSparks`: warm embers rising into the interior
    /// off the burn point and fading out. Replaces the 7 per-frame ember dots.
    private func buildSparkEmitter(scale: CGFloat, into container: CALayer) {
        let pad = FuseMetrics.tipPadding(thickness: thickness, scale: tipScale)
        let reach = thickness / 2 + pad * 0.85
        let r = max(thickness * 0.22, 1) * tipScale

        let lifetime = max(0.6, reach / 18)             // seconds to cross the reach
        let cell = CAEmitterCell()
        cell.contents = bakeEmber(radius: r, scale: scale)
        cell.birthRate = 12
        cell.lifetime = Float(lifetime)
        cell.lifetimeRange = 0.25
        cell.velocity = reach / lifetime                // ~reach over a lifetime
        cell.velocityRange = reach * 0.3
        cell.emissionLongitude = .pi / 2               // +y, into the interior
        cell.emissionRange = .pi / 6
        cell.scale = 1
        cell.scaleRange = 0.4
        cell.scaleSpeed = -0.7                          // shrink as they spend (1 - life·0.7)
        cell.alphaSpeed = Float(-1.0 / lifetime)        // fade out over the lifetime
        cell.color = NSColor(srgbRed: 1, green: 0.9, blue: 0.55, alpha: 0.9).cgColor

        let emitter = CAEmitterLayer()
        emitter.emitterShape = .point
        emitter.emitterPosition = CGPoint(x: 0, y: thickness / 2)
        emitter.emitterCells = [cell]
        emitter.renderMode = .additive
        container.addSublayer(emitter)
        sparkEmitter = emitter
    }

    // MARK: - Per-tick updates

    /// Positions the progress mask (width = filled length) and the tip holder/emitter at the
    /// receding end, optionally gliding both over `tickDuration` so the 0.25s tick reads
    /// smoothly. The notch `skip` case fills two mask pieces around the gap.
    private func applyProgress(animated: Bool) {
        guard let mask = progressMask, let holder = tipHolder else { return }
        let filled = visualProgress * effectiveLength
        let cy = thickness / 2

        let run = { (body: () -> Void) in
            if animated { self.animatingTick(body) } else { self.withoutAnimations(body) }
        }

        let tipX: CGFloat
        if let gap = notchGap, let far = progressMaskFar {
            // Near piece: up to min(filled, gap.start). Far piece: the remainder, shifted
            // across the gap so it sits on the texture stretch past the housing.
            let nearW = max(0, min(filled, gap.start))
            let farLen = max(0, filled - gap.start)
            // Tip rides whichever piece is the leading end.
            tipX = filled <= gap.start ? filled : (gap.start + gap.width) + farLen
            run {
                mask.bounds = CGRect(x: 0, y: 0, width: nearW, height: self.thickness)
                far.frame = CGRect(x: gap.start + gap.width, y: 0, width: farLen, height: self.thickness)
                holder.position = CGPoint(x: tipX, y: cy)
                self.sparkEmitter?.emitterPosition = CGPoint(x: tipX, y: cy)
            }
        } else {
            tipX = filled
            run {
                mask.bounds = CGRect(x: 0, y: 0, width: filled, height: self.thickness)
                holder.position = CGPoint(x: tipX, y: cy)
                self.sparkEmitter?.emitterPosition = CGPoint(x: tipX, y: cy)
            }
        }

        // Hide the tip/sparks before ignition (a zero-coverage mask hides the line, but the
        // tip sprite would still show floating at x=0). The emitter's birthRate is a
        // multiplier on the cell rate — gate it 0/1 so the effective rate stays at the cell's
        // configured value.
        withoutAnimations {
            holder.isHidden = filled <= 0
            sparkEmitter?.birthRate = filled <= 0 ? 0 : 1
        }
    }

    /// Drives the flare (F6) crossfade across the whole fuse: the `flareColor` texture bar
    /// fades over the base line AND the flare flame sprite fades over the tip (both at
    /// `flareFraction`), while the tip+flare grow via the holder scale. Mirrors the old
    /// per-draw `fuseColor → flareColor` blend, which tinted the line and the tip together.
    private func applyFlare() {
        guard let holder = tipHolder, let flare = flareLayer else { return }
        let frac = flareFraction
        let enlarge = 1 + frac * (flareEnlargeScale - 1)
        withoutAnimations {
            flareLineLayer?.opacity = Float(frac)
            flare.opacity = Float(frac)
            holder.transform = CATransform3DMakeScale(enlarge, enlarge, 1)
        }
    }

    // MARK: - Animation helpers

    /// Runs `body` with implicit layer actions disabled (immediate, no animation).
    private func withoutAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Runs `body` inside a `tickDuration` linear transaction so geometry changes glide.
    private func animatingTick(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(tickDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        body()
        CATransaction.commit()
    }

    // MARK: - Offscreen baking

    /// Creates an offscreen bitmap context at `scale` whose user space matches the existing
    /// bottom-left, y-up draw space, runs `body`, and returns the rendered image.
    private func bakedImage(width: CGFloat, height: CGFloat, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let pxW = max(1, Int((width * scale).rounded()))
        let pxH = max(1, Int((height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: deviceRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        body(ctx)
        return ctx.makeImage()
    }

    /// Bakes the full-length texture bar (`drawTexture` verbatim) into a `CGImage`.
    private func bakeTexture(length: CGFloat, cross: CGFloat, color: NSColor, scale: CGFloat) -> CGImage? {
        // `drawTexture` and its sub-helpers read `fuseColor`; swap it for the bake so the
        // same code path serves both the base bar and the `flareColor` bar.
        let saved = fuseColor
        fuseColor = color
        defer { fuseColor = saved }
        return bakedImage(width: max(1, length), height: cross, scale: scale) { ctx in
            drawTexture(in: ctx, length: length, cross: cross)
        }
    }

    /// Bakes the static tip sprite (`drawGlow` or `drawFlame`, including its `setShadow`
    /// blur) centered in a `2·extent` square so the burn point sits at the sprite center.
    private func bakeTip(extent: CGFloat, scale: CGFloat) -> CGImage? {
        let side = extent * 2
        return bakedImage(width: side, height: side, scale: scale) { ctx in
            // Draw with the burn point at the sprite center, in the same y-up flame space:
            // the flame's interior reach (+y) goes up, matching the line's local +y.
            let center = CGPoint(x: extent, y: extent)
            ctx.translateBy(x: center.x, y: center.y - thickness / 2)
            switch tipEffect {
            case .glow:
                drawGlow(in: ctx, at: CGPoint(x: 0, y: thickness / 2), cross: thickness)
            case .flame, .spark:
                // Neutral-size flame; flicker/flare scale it at composite time.
                drawFlame(in: ctx, at: CGPoint(x: 0, y: thickness / 2), cross: thickness)
            }
        }
    }

    /// Bakes a flame sprite tinted by `flareColor` (the crossfade target near the end).
    private func bakeFlareTip(extent: CGFloat, scale: CGFloat) -> CGImage? {
        let side = extent * 2
        let saved = fuseColor
        fuseColor = flareColor
        defer { fuseColor = saved }
        return bakedImage(width: side, height: side, scale: scale) { ctx in
            ctx.translateBy(x: extent, y: extent - thickness / 2)
            drawFlame(in: ctx, at: CGPoint(x: 0, y: thickness / 2), cross: thickness)
        }
    }

    /// Bakes the build-up mode's comet trail. The layer is anchored with its right edge
    /// on the active tip, so the glow stretches backward over the newly drawn fuse.
    private func bakeBuildUpChargeTrail(width: CGFloat, height: CGFloat, scale: CGFloat) -> CGImage? {
        bakedImage(width: width, height: height, scale: scale) { ctx in
            let center = CGPoint(x: width - 1, y: height / 2)
            let clear = fuseColor.withAlphaComponent(0).cgColor
            let hot = NSColor(srgbRed: 1, green: 0.96, blue: 0.78, alpha: 0.95).cgColor
            let warm = blend(fuseColor, NSColor(srgbRed: 1, green: 0.62, blue: 0.12, alpha: 1), 0.45)
                .withAlphaComponent(0.7).cgColor

            ctx.setBlendMode(.plusLighter)
            drawRadial(ctx, deviceRGB, [hot, warm, clear], [0, 0.28, 1],
                       center: center,
                       radius: max(width * 0.35, height * 0.45),
                       scaleX: 1.85,
                       scaleY: 0.32)

            ctx.setStrokeColor(hot)
            ctx.setLineWidth(max(thickness * 0.28, 1))
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: width * 0.18, y: center.y))
            ctx.addLine(to: center)
            ctx.strokePath()
        }
    }

    /// Bakes a single soft ember dot (matching `drawSparks`' blurred ember) for the emitter.
    private func bakeEmber(radius r: CGFloat, scale: CGFloat) -> CGImage? {
        let blur = r * 1.6
        let side = (r + blur) * 2
        let c = side / 2
        return bakedImage(width: side, height: side, scale: scale) { ctx in
            ctx.setShadow(offset: .zero, blur: blur,
                          color: NSColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 0.9).cgColor)
            ctx.setFillColor(NSColor(srgbRed: 1, green: 0.9, blue: 0.55, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: c - r, y: c - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: - Texture (drawn within the thickness band)

    private func drawTexture(in ctx: CGContext, length: CGFloat, cross: CGFloat) {
        let band = CGRect(x: 0, y: 0, width: length, height: cross)
        ctx.saveGState()
        ctx.clip(to: band)

        ctx.setFillColor(fuseColor.cgColor)
        ctx.fill(band)

        switch texture {
        case .solid:
            break
        case .rope:
            drawRoundShading(in: ctx, band: band)
            drawRopeStrands(in: ctx, band: band)
        case .wick:
            drawRoundShading(in: ctx, band: band)
            drawWickBindings(in: ctx, band: band)
        }
        ctx.restoreGState()
    }

    /// A cylindrical sheen across the band: shaded edges, a soft highlight down the
    /// middle. Makes the cord read as round rather than a flat ribbon.
    private func drawRoundShading(in ctx: CGContext, band: CGRect) {
        let space = deviceRGB
        let clear = fuseColor.withAlphaComponent(0).cgColor
        let edge = darken(fuseColor, 0.4).withAlphaComponent(0.55).cgColor
        let sheen = lighten(fuseColor, 0.55).withAlphaComponent(0.5).cgColor
        let bottom = CGPoint(x: band.midX, y: band.minY)
        let top = CGPoint(x: band.midX, y: band.maxY)

        if let g = CGGradient(colorsSpace: space, colors: [edge, clear, clear, edge] as CFArray,
                              locations: [0, 0.3, 0.7, 1]) {
            ctx.drawLinearGradient(g, start: bottom, end: top, options: [])
        }
        if let g = CGGradient(colorsSpace: space, colors: [clear, sheen, clear] as CFArray,
                              locations: [0.32, 0.5, 0.68]) {
            ctx.drawLinearGradient(g, start: bottom, end: top, options: [])
        }
    }

    /// Diagonal light strands with shadowed grooves between them — a braided twist.
    private func drawRopeStrands(in ctx: CGContext, band: CGRect) {
        let c = band.height
        let period = max(c * 1.25, 5)
        let light = lighten(fuseColor, 0.6).withAlphaComponent(0.5).cgColor
        let groove = darken(fuseColor, 0.45).withAlphaComponent(0.45).cgColor

        ctx.setLineCap(.butt)
        var x = -c
        while x < band.maxX {
            ctx.setStrokeColor(light)
            ctx.setLineWidth(max(c * 0.2, 1))
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x + c, y: c))
            ctx.strokePath()

            ctx.setStrokeColor(groove)
            ctx.setLineWidth(max(c * 0.12, 0.5))
            ctx.move(to: CGPoint(x: x + period * 0.5, y: 0))
            ctx.addLine(to: CGPoint(x: x + period * 0.5 + c, y: c))
            ctx.strokePath()

            x += period
        }
    }

    /// Periodic darker cross-bands, like the wrappings on a wick/cord.
    private func drawWickBindings(in ctx: CGContext, band: CGRect) {
        let c = band.height
        let period = max(c * 1.8, 8)
        let w = period * 0.3
        ctx.setFillColor(darken(fuseColor, 0.45).withAlphaComponent(0.7).cgColor)
        var x = period * 0.5
        while x < band.maxX {
            ctx.fill(CGRect(x: x - w / 2, y: 0, width: w, height: c))
            x += period
        }
    }

    // MARK: - Burning tip

    /// A brighter/whiter dot with a soft glow (classic).
    private func drawGlow(in ctx: CGContext, at center: CGPoint, cross c: CGFloat) {
        let radius = max(c * 0.9, 3) * tipScale
        let dotRect = CGRect(x: center.x - radius, y: center.y - radius,
                             width: radius * 2, height: radius * 2)
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

    /// A layered flame at the burn point: a fuse-tinted halo, an amber body, and a
    /// white-hot core. The hot core sits on the line and the flame bulges into the
    /// interior `tipPadding` headroom (slightly past the configured width) and licks a
    /// little along the burn axis. Baked once at the neutral size; the tip layer's
    /// flicker keyframe and flare scale animate it at composite time.
    private func drawFlame(in ctx: CGContext, at tip: CGPoint, cross c: CGFloat) {
        let space = deviceRGB
        let clear = fuseColor.withAlphaComponent(0).cgColor

        // Reach from the line center toward the interior; kept just inside the headroom
        // so the gradient's alpha has faded out before the strip edge clips it.
        let reach = c / 2 + FuseMetrics.tipPadding(thickness: c, scale: tipScale) * 0.85
        let center = CGPoint(x: tip.x, y: c / 2)

        // Outer halo, tinted by the fuse color so the line's hue carries into the flame.
        let halo = blend(fuseColor, NSColor(srgbRed: 1, green: 0.35, blue: 0.05, alpha: 1), 0.5)
            .withAlphaComponent(0.5).cgColor
        drawRadial(ctx, space, [halo, clear], [0, 1],
                   center: center, radius: reach, scaleX: 1.3, scaleY: 1.0)

        // Amber body with a hot core.
        let amber = NSColor(srgbRed: 1, green: 0.72, blue: 0.18, alpha: 0.95).cgColor
        let core = NSColor(srgbRed: 1, green: 0.98, blue: 0.85, alpha: 1).cgColor
        drawRadial(ctx, space, [core, amber, clear], [0, 0.4, 1],
                   center: center, radius: reach * 0.7, scaleX: 1.45, scaleY: 1.0)

        // Tight white-hot center right at the burn point on the line.
        let white = NSColor(srgbRed: 1, green: 1, blue: 0.95, alpha: 1).cgColor
        drawRadial(ctx, space, [white, clear], [0, 1],
                   center: tip, radius: max(c * 0.7, 3.5) * tipScale, scaleX: 1.4, scaleY: 1.2)
    }

    // MARK: - Drawing helpers

    /// Draws a radial gradient (center → edge) at `center`, optionally elongated by
    /// `scaleX`/`scaleY` to make a flame lick along an axis.
    private func drawRadial(_ ctx: CGContext, _ space: CGColorSpace,
                            _ colors: [CGColor], _ locations: [CGFloat],
                            center: CGPoint, radius: CGFloat,
                            scaleX: CGFloat, scaleY: CGFloat) {
        guard radius > 0,
              let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
        else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: scaleX, y: scaleY)
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0,
                               endCenter: .zero, endRadius: radius, options: [])
        ctx.restoreGState()
    }

    /// A gentle multi-sine flicker in roughly 0.7...1.15, sampled at integer `phase`. The
    /// old per-frame redraw advanced `phase` by 1 each 1/30s frame; the GPU keyframe
    /// animation now samples this same curve at those frame indices. Baseline only
    /// (no `intensify`) — flare's amplification is folded into the flare layer's scale.
    private func flicker(phase: Int) -> CGFloat {
        let t = CGFloat(phase)
        let v = 0.9 + 0.1 * sin(t * 0.45) + 0.05 * sin(t * 1.3 + 1.7)
        return max(0.7, min(1.15, v))
    }

    private func lighten(_ color: NSColor, _ amount: CGFloat) -> NSColor {
        blend(color, .white, amount)
    }

    private func darken(_ color: NSColor, _ amount: CGFloat) -> NSColor {
        blend(color, .black, amount)
    }

    /// Linearly interpolates two colors in sRGB.
    private func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let x = a.usingColorSpace(.sRGB) ?? a
        let y = b.usingColorSpace(.sRGB) ?? b
        let u = max(0, min(1, t))
        return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * u,
                       green: x.greenComponent + (y.greenComponent - x.greenComponent) * u,
                       blue: x.blueComponent + (y.blueComponent - x.blueComponent) * u,
                       alpha: x.alphaComponent + (y.alphaComponent - x.alphaComponent) * u)
    }
}
