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
    /// `base` = candle body and wick, `top` = flame (or the smoke curl when out). The menu bar candle
    /// draws the base once and lets the flame sway as its own layer, so the sway costs no drawing.
    static func draw(awake: Bool, in rect: NSRect, color: NSColor, lineWidth: CGFloat, flicker: CGFloat = 0,
                     base drawBase: Bool = true, top drawTop: Bool = true) {
        let h = rect.height
        let cx = rect.midX
        color.setStroke(); color.setFill()
        if !drawBase && !drawTop { return }

        // Candle body: a short rounded column at the bottom.
        let bodyW = h * 0.40, bodyH = h * 0.38
        let body = NSRect(x: cx - bodyW / 2, y: rect.minY, width: bodyW, height: bodyH)
        if drawBase {
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: lineWidth * 0.9, yRadius: lineWidth * 0.9)
        bodyPath.lineWidth = lineWidth
        bodyPath.fill()   // solid candle body, lit or not
        bodyPath.stroke()
        }

        // Wick.
        let wickTop = body.maxY + h * (awake ? 0.13 : 0.05)   // shorter, trimmed wick when out
        if drawBase {
        let wick = NSBezierPath()
        wick.move(to: NSPoint(x: cx, y: body.maxY))
        wick.line(to: NSPoint(x: cx, y: wickTop))
        wick.lineWidth = lineWidth * 0.8
        wick.lineCapStyle = .round
        wick.stroke()
        }

        if !drawTop { return }
        if awake {
            // Teardrop flame sitting on the wick, with a hollow core so it reads at 16 px.
            let fh = h * 0.36 * (1 + flicker * 0.06)
            let fw = h * 0.30
            let base = flameBase(in: rect)   // small gap so the flame reads apart from the solid body
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

    /// The padded drawing box and line width the menu bar candle uses inside `size`.
    static func metrics(size: NSSize) -> (box: NSRect, lineWidth: CGFloat) {
        let lineWidth = max(1.4, size.height * 0.095)
        var box = NSRect(origin: .zero, size: size).insetBy(dx: lineWidth * 0.5, dy: lineWidth * 0.5)
        // Menu bar copy: lift the base 5.5 pt so the candle's floor lines up with the other icons'.
        if size == menuCanvas { box.origin.y += 5.5; box.size.height -= 3.5 }
        return (box, lineWidth)
    }

    /// Where the flame sits on the wick (also the point it sways around).
    static func flameBase(in rect: NSRect) -> NSPoint {
        let h = rect.height
        let bodyTop = rect.minY + h * 0.38
        return NSPoint(x: rect.midX, y: bodyTop + h * 0.13 - h * 0.02)
    }

    /// A ready image of the glyph. `color == nil` makes a black template image.
    static func image(awake: Bool, size: NSSize = menuCanvas, color: NSColor? = nil, flicker: CGFloat = 0) -> NSImage {
        let (box, lineWidth) = metrics(size: size)
        let img = NSImage(size: size, flipped: false) { _ in
            draw(awake: awake, in: box,
                 color: color ?? .black, lineWidth: lineWidth, flicker: flicker)
            return true
        }
        img.isTemplate = (color == nil)
        img.accessibilityDescription = awake ? "Awayke: awake" : "Awayke: off"
        return img
    }
}

/// The live menu bar candle. The candle body is drawn once; the flame is its own layer that Core
/// Animation sways in the render server, so a lit candle costs the app no CPU (the earlier version
/// redrew 12 times a second and used about 15% of a core). Nothing swaps `button.image`, which is
/// what made macOS show the candle upside down for a moment.
final class CandleView: NSView {
    var awake = false { didSet { if awake != oldValue { refresh() } } }
    /// nil = template look (follows the menu bar's white/black); otherwise the accent fill.
    var color: NSColor? { didSet { refresh() } }
    /// Gentle sway on while true (off for Reduce Motion or when the candle is out).
    var swaying = false { didSet { if swaying != oldValue { syncSway() } } }

    private let flameLayer = CALayer()
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the button

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(flameLayer)
        flameLayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "anchorPoint": NSNull()]
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() { refresh() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    override func layout() { super.layout(); refresh() }

    /// True while the sway animation is attached (the poll re-attaches it if macOS dropped it).
    var swayAttached: Bool { flameLayer.animation(forKey: "sway") != nil }

    func refresh() {
        needsDisplay = true
        let size = EyeGlyph.menuCanvas
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        flameLayer.isHidden = !awake
        guard awake, bounds.width > 0 else { syncSway(); return }
        let (box, lineWidth) = EyeGlyph.metrics(size: size)
        let tint = color ?? .labelColor
        var cg: CGImage?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let img = NSImage(size: size, flipped: false) { _ in
                EyeGlyph.draw(awake: true, in: box, color: tint, lineWidth: lineWidth, base: false, top: true)
                return true
            }
            var rect = NSRect(origin: .zero, size: size)
            cg = img.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scaleByX: scale, byY: scale)])
        }
        let anchorPt = EyeGlyph.flameBase(in: box)
        flameLayer.contentsScale = scale
        flameLayer.contents = cg
        flameLayer.bounds = CGRect(origin: .zero, size: size)
        flameLayer.anchorPoint = CGPoint(x: anchorPt.x / size.width, y: anchorPt.y / size.height)
        flameLayer.position = CGPoint(x: bounds.width * flameLayer.anchorPoint.x, y: bounds.height * flameLayer.anchorPoint.y)
        syncSway()
    }

    /// Attach or remove the sway. Two slow, unrelated waves (lean and stretch) so it never looks like a loop.
    func syncSway() {
        guard swaying, awake else {
            flameLayer.removeAnimation(forKey: "sway"); flameLayer.removeAnimation(forKey: "stretch"); return
        }
        guard !swayAttached else { return }
        let lean = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        lean.values = [0, 0.10, 0, -0.10, 0]
        lean.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        lean.calculationMode = .cubic
        lean.duration = 4.4
        lean.repeatCount = .infinity
        lean.isRemovedOnCompletion = false
        flameLayer.add(lean, forKey: "sway")
        let stretch = CAKeyframeAnimation(keyPath: "transform.scale.y")
        stretch.values = [1, 1.06, 1, 0.97, 1]
        stretch.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        stretch.calculationMode = .cubic
        stretch.duration = 3.1
        stretch.repeatCount = .infinity
        stretch.isRemovedOnCompletion = false
        flameLayer.add(stretch, forKey: "stretch")
    }

    override func draw(_ dirtyRect: NSRect) {
        let (box, lineWidth) = EyeGlyph.metrics(size: EyeGlyph.menuCanvas)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            EyeGlyph.draw(awake: awake, in: box, color: color ?? .labelColor,
                          lineWidth: lineWidth, base: true, top: !awake)   // lit: the flame is the layer above
        }
    }
}
