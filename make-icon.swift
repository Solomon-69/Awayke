// Awayke app icon generator (native, AppKit-rendered). Output files keep the
// internal "Sleepless" name so build.sh and Info.plist (CFBundleIconFile) still match.
//
// Renders the SAME eye mark the menu bar uses (open eye + spark = "kept awake"), in white
// on a continuous-curvature ("squircle") plate carrying the Ember orange gradient, so the
// Dock/Finder icon matches the menu-bar glyph and the popover accent. Every iconset size is
// drawn straight from vector paths (no raster downscaling).
//
// Build + run:  swiftc -O -framework AppKit make-icon.swift -o /tmp/mkicon && /tmp/mkicon [outDir]
// Then:         iconutil -c icns Sleepless.iconset -o Sleepless.icns
//
// Output directory = first CLI argument, else the current working directory.
import AppKit

// ---- Ember palette: warm amber top-left -> Ember orange -> deep ember bottom-right.
let plateTop = NSColor(srgbRed: 1.00, green: 0.75, blue: 0.30, alpha: 1) // #FFBF4D
let plateMid = NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1) // #FF9F0A Ember
let plateBot = NSColor(srgbRed: 0.85, green: 0.36, blue: 0.02, alpha: 1) // #D95C05

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath
let iconset = "\(outDir)/Sleepless.iconset"

// Continuous-curvature squircle path (superellipse, exponent ~5 ~= Apple plate).
func squirclePath(rect: CGRect, n: CGFloat = 5.0) -> CGPath {
    let p = CGMutablePath()
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2.0 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2.0 / n), st)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

// Awayke mark: one clean flame (the lit candle reduced to its essence), with a soft cut-out core.
func drawCandle(in rect: NSRect, color: NSColor, lineWidth: CGFloat) {
    let h = rect.height, cx = rect.midX
    let fw = h * 0.62, base = rect.minY + h * 0.06, tip = rect.maxY - h * 0.02
    let fh = tip - base
    color.setFill()
    // Tip leans right and the left side swells, so it reads as a flickering flame, not a drop.
    let flame = NSBezierPath()
    let t = NSPoint(x: cx + fw * 0.14, y: tip)
    flame.move(to: t)
    flame.curve(to: NSPoint(x: cx + fw * 0.50, y: base + fh * 0.30),
                controlPoint1: NSPoint(x: cx + fw * 0.30, y: tip - fh * 0.22),
                controlPoint2: NSPoint(x: cx + fw * 0.56, y: base + fh * 0.48))
    flame.curve(to: NSPoint(x: cx, y: base),
                controlPoint1: NSPoint(x: cx + fw * 0.46, y: base + fh * 0.10),
                controlPoint2: NSPoint(x: cx + fw * 0.26, y: base))
    flame.curve(to: NSPoint(x: cx - fw * 0.50, y: base + fh * 0.34),
                controlPoint1: NSPoint(x: cx - fw * 0.28, y: base),
                controlPoint2: NSPoint(x: cx - fw * 0.50, y: base + fh * 0.14))
    flame.curve(to: t,
                controlPoint1: NSPoint(x: cx - fw * 0.50, y: base + fh * 0.62),
                controlPoint2: NSPoint(x: cx - fw * 0.06, y: tip - fh * 0.30))
    flame.close(); flame.fill()
    if let ctx = NSGraphicsContext.current {
        ctx.saveGraphicsState(); ctx.compositingOperation = .destinationOut
        let cw = fw * 0.36, ch = fh * 0.42, cb = base + fh * 0.12
        let core = NSBezierPath()
        core.move(to: NSPoint(x: cx, y: cb + ch))
        core.curve(to: NSPoint(x: cx, y: cb), controlPoint1: NSPoint(x: cx + cw * 0.95, y: cb + ch * 0.38), controlPoint2: NSPoint(x: cx + cw * 0.62, y: cb))
        core.curve(to: NSPoint(x: cx, y: cb + ch), controlPoint1: NSPoint(x: cx - cw * 0.62, y: cb), controlPoint2: NSPoint(x: cx - cw * 0.95, y: cb + ch * 0.38))
        core.close()
        NSColor(white: 0, alpha: 1).setFill(); core.fill()
        ctx.restoreGraphicsState()
    }
}

func renderIcon(_ S: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // Apple plate grid: ~824 plate on 1024 canvas (≈100px gutter), scaled to S.
    let gutter = S * (100.0 / 1024.0)
    let plate = CGRect(x: gutter, y: gutter, width: S - 2 * gutter, height: S - 2 * gutter)
    let path = squirclePath(rect: plate)

    // Plate fill: indigo -> violet -> fuchsia diagonal gradient (lighter top-left,
    // deeper bottom-right) so it agrees with the system icon lighting.
    cg.saveGState()
    cg.addPath(path); cg.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: cs,
        colors: [plateTop.cgColor, plateMid.cgColor, plateBot.cgColor] as CFArray,
        locations: [0, 0.5, 1])!
    cg.drawLinearGradient(grad,
        start: CGPoint(x: plate.minX, y: plate.maxY),   // top-left (light indigo)
        end:   CGPoint(x: plate.maxX, y: plate.minY),   // bottom-right (deep fuchsia)
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    cg.restoreGState()

    // The eye mark (same geometry as Glyph.swift), white, with a soft warm drop shadow.
    let small = S <= 64
    let markH = plate.height * (small ? 0.66 : 0.52)
    let mark = NSRect(x: plate.midX - markH / 2, y: plate.midY - markH / 2, width: markH, height: markH)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -S * 0.008), blur: S * 0.02,
                 color: NSColor(srgbRed: 0.45, green: 0.16, blue: 0.0, alpha: 0.45).cgColor)
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    drawCandle(in: mark, color: .white, lineWidth: markH * (small ? 0.09 : 0.06))
    cg.endTransparencyLayer()
    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ path: String) {
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
try? fm.removeItem(atPath: iconset)
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// 10 standard iconset entries (size, @2x?) -> render each directly from vector.
let specs: [(String, CGFloat)] = [
    ("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
    ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),
    ("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024),
]
for (name, px) in specs { write(renderIcon(px), "\(iconset)/\(name).png") }
write(renderIcon(1024), "\(outDir)/Sleepless-1024.png")
print("rendered iconset (\(specs.count) sizes) + Sleepless-1024.png")
