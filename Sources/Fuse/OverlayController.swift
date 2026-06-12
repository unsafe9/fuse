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
        let texture = SettingsStore.shared.fuseTexture
        let tipEffect = SettingsStore.shared.fuseTipEffect

        for screen in targetScreens() {
            let frame = stripFrame(for: screen.frame, position: position, thickness: thickness)
            let window = OverlayWindow(contentRect: frame)
            let view = FuseView(frame: NSRect(origin: .zero, size: frame.size))
            view.position = position
            view.fuseColor = color
            view.thickness = thickness
            view.texture = texture
            view.tipEffect = tipEffect
            view.setProgress(renderProgress)
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
            (window.contentView as? FuseView)?.tick(progress: progress)
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

    /// A strip along `position` edge of `screenFrame` (global coords). The line itself is
    /// `thickness`, but the strip is widened on its interior side by `tipPadding` so the
    /// burning tip can bulge a bit past the line without being clipped.
    private func stripFrame(for screenFrame: NSRect, position: FusePosition, thickness: CGFloat) -> NSRect {
        let band = thickness + FuseMetrics.tipPadding(thickness: thickness)
        switch position {
        case .top:
            return NSRect(x: screenFrame.minX, y: screenFrame.maxY - band,
                          width: screenFrame.width, height: band)
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
    /// burning tip can spill a little past the line's configured thickness.
    static func tipPadding(thickness: CGFloat) -> CGFloat {
        max(thickness * 1.4, 12)
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

/// Layer-backed view rendering the fuse line, its chosen texture, and its burning tip.
///
/// Draws a filled bar of length `progress × edgeLength` from the anchored end, in
/// `SettingsStore.shared.fuseColor` at `fuseThickness`, overlaid with the selected
/// `FuseTexture` (solid / rope / wick) and ending in the selected `FuseTipEffect`
/// (glow / flame / sparks). All drawing happens in a local space where +x is the burn
/// direction and +y points toward the screen interior, so one code path serves all four
/// edges. The texture only shades the `thickness` bar; the tip is allowed to bulge a
/// little past the line into the strip's interior `FuseMetrics.tipPadding` headroom.
/// Reads progress live from `TimerEngine.shared`; the 1/30s render timer also advances
/// a flicker `phase` so animated tips shimmer. Set frames directly / disable implicit
/// actions so the render timer is authoritative.
///
/// OWNER: overlay.
final class FuseView: NSView {
    /// Edge the fuse is drawn along; controls anchoring + axis.
    var position: FusePosition = .top
    var fuseColor: NSColor = .red
    var thickness: CGFloat = 4
    var texture: FuseTexture = .rope
    var tipEffect: FuseTipEffect = .flame

    private var progress: Double = 1
    /// Monotonic frame counter driving tip flicker; advanced by the render timer.
    private var phase: Int = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The render timer is authoritative; suppress implicit animations.
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Sets the progress and forces a redraw (initial draw / settings change).
    func setProgress(_ progress: Double) {
        self.progress = min(1, max(0, progress))
        needsDisplay = true
    }

    /// Called by the render timer: stores progress, advances the flicker phase, and
    /// redraws when the bar moved or the chosen tip effect animates.
    func tick(progress: Double) {
        let clamped = min(1, max(0, progress))
        let moved = clamped != self.progress
        self.progress = clamped
        phase &+= 1
        if moved || tipEffect.isAnimated { needsDisplay = true }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        let horizontal = position.isHorizontal
        // Length along the burning axis; the cross-axis is the strip (band + headroom).
        let edgeLength = horizontal ? bounds.width : bounds.height
        let filled = CGFloat(progress) * edgeLength
        guard filled > 0 else { return }

        ctx.saveGState()
        // Map the local frame (x = burn direction with tip at x = filled, y = 0 at the
        // screen edge, +y toward the interior) onto the view. Each edge needs its own
        // transform, but a single set of drawing code then serves all four positions.
        switch position {
        case .top:
            ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height))
        case .bottom:
            break
        case .left:
            ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
        case .right:
            ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: bounds.width, ty: 0))
        }

        drawTexture(in: ctx, length: filled, cross: thickness)
        drawTip(in: ctx, at: CGPoint(x: filled, y: thickness / 2), cross: thickness)
        ctx.restoreGState()
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
        let space = CGColorSpaceCreateDeviceRGB()
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

    private func drawTip(in ctx: CGContext, at tip: CGPoint, cross c: CGFloat) {
        switch tipEffect {
        case .glow:
            drawGlow(in: ctx, at: tip, cross: c)
        case .flame:
            drawFlame(in: ctx, at: tip, cross: c)
        case .spark:
            drawFlame(in: ctx, at: tip, cross: c)
            drawSparks(in: ctx, at: tip, cross: c)
        }
    }

    /// A brighter/whiter dot with a soft glow (classic).
    private func drawGlow(in ctx: CGContext, at center: CGPoint, cross c: CGFloat) {
        let radius = max(c * 0.9, 3)
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
    /// little along the burn axis. A gentle flicker scales it each frame.
    private func drawFlame(in ctx: CGContext, at tip: CGPoint, cross c: CGFloat) {
        let space = CGColorSpaceCreateDeviceRGB()
        let f = flicker()
        let clear = fuseColor.withAlphaComponent(0).cgColor

        // Reach from the line center toward the interior; kept just inside the headroom
        // so the gradient's alpha has faded out before the strip edge clips it.
        let reach = (c / 2 + FuseMetrics.tipPadding(thickness: c) * 0.85) * f
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
                   center: tip, radius: max(c * 0.7, 3.5), scaleX: 1.4, scaleY: 1.2)
    }

    /// A few flickering embers rising off the burn point into the interior, fading with
    /// their deterministic per-frame "life" so they twinkle without random state.
    private func drawSparks(in ctx: CGContext, at tip: CGPoint, cross c: CGFloat) {
        let pad = FuseMetrics.tipPadding(thickness: c)
        let reach = c / 2 + pad * 0.85
        let ember = NSColor(srgbRed: 1, green: 0.9, blue: 0.55, alpha: 1)
        for i in 0..<7 {
            let seed = phase / 2 + i * 37
            let life = hash01(seed)                              // 0 = fresh, 1 = spent
            let sx = tip.x + (hash01(seed &* 7) - 0.5) * pad * 0.7  // sway along the fuse
            let sy = c / 2 + life * reach                          // rises into the interior
            let alpha = (1 - life) * 0.9
            let r = max(c * 0.22, 1) * (1 - life * 0.7)
            guard alpha > 0.05, r > 0.4 else { continue }
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: r * 1.6,
                          color: NSColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: alpha).cgColor)
            ctx.setFillColor(ember.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2))
            ctx.restoreGState()
        }
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

    /// A gentle multi-sine flicker in roughly 0.7...1.15, deterministic in `phase`.
    private func flicker() -> CGFloat {
        let t = CGFloat(phase)
        let v = 0.9 + 0.1 * sin(t * 0.45) + 0.05 * sin(t * 1.3 + 1.7)
        return max(0.7, min(1.15, v))
    }

    /// A reproducible pseudo-random value in 0...1 from an integer seed (no RNG state).
    private func hash01(_ n: Int) -> CGFloat {
        let s = sin(CGFloat(n) * 12.9898) * 43758.5453
        return s - floor(s)
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
