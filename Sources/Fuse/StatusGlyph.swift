import AppKit

/// Builds the custom menu bar status icon: a stylized burning fuse.
///
/// A smooth S-curved cord runs from the lower-left to the upper-right, ending in
/// a small spark burst at its tip with a couple of tiny embers. The image is a
/// template image (black + alpha only) so AppKit tints it for light/dark menu bars.
enum StatusGlyph {
    /// Point size of the status icon. The menu bar is ~22pt tall; ~18pt reads well.
    static let size = NSSize(width: 18, height: 18)

    /// Returns the template status-bar image. Rendered via a resolution-independent
    /// drawing handler so AppKit produces crisp output at any backing scale.
    static func makeImage() -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Fuse"
        return image
    }

    private static func draw() {
        let w = size.width
        let h = size.height

        // S-curved cord, lower-left -> upper-right, kept inside the central region
        // so the spark at the tip never clips against the menu-bar edges.
        let start = NSPoint(x: 0.18 * w, y: 0.16 * h)
        let tip = NSPoint(x: 0.74 * w, y: 0.74 * h)
        let c1 = NSPoint(x: 0.62 * w, y: 0.14 * h)
        let c2 = NSPoint(x: 0.30 * w, y: 0.78 * h)

        let cord = NSBezierPath()
        cord.move(to: start)
        cord.curve(to: tip, controlPoint1: c1, controlPoint2: c2)
        cord.lineWidth = 2.0
        cord.lineCapStyle = .round
        cord.lineJoinStyle = .round
        NSColor.black.setStroke()
        cord.stroke()

        // Spark burst at the cord tip: a small N-point star.
        let burst = starPath(center: tip, points: 5, outer: 0.20 * w, inner: 0.075 * w, rotation: .pi / 10)
        NSColor.black.setFill()
        burst.fill()

        // A couple of tiny embers drifting off the spark; sized to stay crisp.
        let emberR = 0.045 * w
        for offset in [NSPoint(x: 0.93 * w, y: 0.62 * h), NSPoint(x: 0.86 * w, y: 0.92 * h)] {
            let rect = NSRect(
                x: offset.x - emberR,
                y: offset.y - emberR,
                width: emberR * 2,
                height: emberR * 2
            )
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    /// Builds an `points`-pointed star centered at `center`.
    private static func starPath(center: NSPoint, points: Int, outer: CGFloat, inner: CGFloat, rotation: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let step = CGFloat.pi / CGFloat(points)
        for i in 0..<(points * 2) {
            let r = (i % 2 == 0) ? outer : inner
            let angle = rotation + CGFloat(i) * step
            let p = NSPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        return path
    }
}
