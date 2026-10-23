// Glyph.swift. The Awayke menu bar candle, drawn in code so every size stays crisp.
//
//   AWAKE = a lit candle with a teardrop flame.
//   OFF   = an unlit candle with a thin wisp of smoke.
//
// The menu bar draws both states into ONE fixed canvas (no size or position jitter).
// OFF is a monochrome template image (macOS tints it white/black to suit the menu bar);
// AWAKE is either filled in the user's accent colour (non-template) or a template too,
// depending on the "Menu bar icon" setting.
import AppKit

enum EyeGlyph {
    /// Menu-bar canvas, whole points only (both states share it).
    static let menuCanvas = NSSize(width: 18, height: 24)

    /// Draw the candle into `rect` (y-up coordinates). `color` paints every part.
    /// AWAKE = lit candle with a teardrop flame; OFF = unlit candle with a thin wisp of smoke.
    /// `flicker` (-1...1) leans and stretches the flame slightly for the flicker animation.
    static func draw(awake: Bool, in rect: NSRect, color: NSColor, lineWidth: CGFloat, flicker: CGFloat = 0) {
        let h = rect.height
        let cx = rect.midX
        color.setStroke(); color.setFill()

        // Candle body: a short rounded column at the bottom.
        let bodyW = h * 0.40, bodyH = h * 0.38
        let body = NSRect(x: cx - bodyW / 2, y: rect.minY, width: bodyW, height: bodyH)
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: lineWidth * 0.9, yRadius: lineWidth * 0.9)
        bodyPath.lineWidth = lineWidth
        bodyPath.fill()   // solid candle body, lit or not
        bodyPath.stroke()

        // Wick.
        let wickTop = body.maxY + h * (awake ? 0.13 : 0.05)   // shorter, trimmed wick when out
        let wick = NSBezierPath()
        wick.move(to: NSPoint(x: cx, y: body.maxY))
        wick.line(to: NSPoint(x: cx, y: wickTop))
        wick.lineWidth = lineWidth * 0.8
        wick.lineCapStyle = .round
        wick.stroke()

        if awake {
            // Teardrop flame sitting on the wick, with a hollow core so it reads at 16 px.
            let fh = h * 0.36 * (1 + flicker * 0.06)
            let fw = h * 0.30
            let base = NSPoint(x: cx, y: wickTop - h * 0.02)   // small gap so the flame reads apart from the solid body
            let tip = NSPoint(x: cx + flicker * fw * 0.18, y: min(rect.maxY, base.y + fh))
            let flame = NSBezierPath()
            flame.move(to: tip)
            flame.curve(to: NSPoint(x: cx, y: base.y),
                        controlPoint1: NSPoint(x: cx + fw * 0.95, y: base.y + fh * 0.30),
                        controlPoint2: NSPoint(x: cx + fw * 0.55, y: base.y))
            flame.curve(to: tip,
                        controlPoint1: NSPoint(x: cx - fw * 0.55, y: base.y),
                        controlPoint2: NSPoint(x: cx - fw * 0.95, y: base.y + fh * 0.30))
            flame.close()
            flame.fill()
            if let ctx = NSGraphicsContext.current {
                ctx.saveGraphicsState()
                ctx.compositingOperation = .clear
                let core = fw * 0.34
                NSBezierPath(ovalIn: NSRect(x: cx - core / 2, y: base.y + fh * 0.12,
                                            width: core, height: core * 1.35)).fill()
                ctx.restoreGraphicsState()
            }
        } else {
            // A thin curl of smoke = "just went out / asleep".
            let smoke = NSBezierPath()
            let sy = wickTop + h * 0.06
            smoke.move(to: NSPoint(x: cx, y: sy))
            smoke.curve(to: NSPoint(x: cx + h * 0.02, y: min(rect.maxY, sy + h * 0.24)),
                        controlPoint1: NSPoint(x: cx + h * 0.16, y: sy + h * 0.07),
                        controlPoint2: NSPoint(x: cx - h * 0.14, y: sy + h * 0.16))
            smoke.lineWidth = lineWidth * 0.75
            smoke.lineCapStyle = .round
            smoke.stroke()
        }
    }

    /// A ready image of the glyph. `color == nil` makes a black template image.
    static func image(awake: Bool, size: NSSize = menuCanvas, color: NSColor? = nil, flicker: CGFloat = 0) -> NSImage {
        let lineWidth = max(1.4, size.height * 0.095)
        let img = NSImage(size: size, flipped: false) { r in
            // Menu bar copy: lift the base 5.5 pt so the candle's floor lines up with the other icons'.
            var box = r.insetBy(dx: lineWidth * 0.5, dy: lineWidth * 0.5)
            if size == menuCanvas { box.origin.y += 5.5; box.size.height -= 3.5 }
            draw(awake: awake, in: box,
                 color: color ?? .black, lineWidth: lineWidth, flicker: flicker)
            return true
        }
        img.isTemplate = (color == nil)
        img.accessibilityDescription = awake ? "Awayke: awake" : "Awayke: off"
        return img
    }
}

/// The menu bar candle as a live view on top of the status button.
/// Why a view and not `button.image`: swapping the button's picture every half second (with a cross-fade on the
/// button's own layer) let macOS cross-fade stale, sometimes upside-down snapshots of the button after the Mac had
/// been awake for a long while, or after sleep / a display change: the candle "flipped". This view is never flipped,
/// never swaps pictures and never uses a layer transition; it just redraws itself in place.
final class CandleView: NSView {
    var awake = false { didSet { if awake != oldValue { needsDisplay = true } } }
    /// nil = follow the menu bar like a template icon (white on a dark bar, black on a light one).
    var color: NSColor? { didSet { if color != oldValue { needsDisplay = true } } }
    var flicker: CGFloat = 0 { didSet { if abs(flicker - oldValue) > 0.0005 { needsDisplay = true } } }

    override var isFlipped: Bool { false }        // y goes up, always: the candle can never draw upside down
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the button underneath
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    private var inkColor: NSColor {
        if let c = color { return c }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
        return dark ? .white : .black
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = EyeGlyph.menuCanvas
        // the same spot a centred, unscaled button image would take, on whole points
        let origin = NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded())
        let lineWidth = max(1.4, size.height * 0.095)
        var box = NSRect(origin: origin, size: size).insetBy(dx: lineWidth * 0.5, dy: lineWidth * 0.5)
        box.origin.y += 5.5; box.size.height -= 3.5
        NSGraphicsContext.current?.saveGraphicsState()
        // draw on a transparency layer so the flame's hollow core clears only the flame, never what is underneath
        NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        EyeGlyph.draw(awake: awake, in: box, color: inkColor, lineWidth: lineWidth, flicker: flicker)
        NSGraphicsContext.current?.cgContext.endTransparencyLayer()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// A clear picture the size of the candle, kept on the button for its width, highlight and accessibility.
    static func placeholder(label: String) -> NSImage {
        let img = NSImage(size: EyeGlyph.menuCanvas, flipped: false) { _ in true }
        img.isTemplate = true
        img.accessibilityDescription = label
        return img
    }
}
