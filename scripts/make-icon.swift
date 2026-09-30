// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }

let accent = rgb(255, 106, 61)

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 186 * s, yRadius: 186 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 30 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    rgb(18, 18, 20).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Graphite tile with a soft top light, like polished glass over black.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [rgb(52, 52, 58), rgb(22, 22, 26), rgb(10, 10, 12)])!.draw(in: tile, angle: -90)
    NSGradient(colors: [.white.withAlphaComponent(0.16), .white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 512 * s, y: 980 * s), radius: 0, toCenter: NSPoint(x: 512 * s, y: 980 * s), radius: 620 * s, options: [])
    // A faint warm reflection of the live light on the tile.
    NSGradient(colors: [accent.withAlphaComponent(0.22), accent.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 700 * s, y: 380 * s), radius: 0, toCenter: NSPoint(x: 700 * s, y: 380 * s), radius: 420 * s, options: [])

    // White speech bubble.
    let body = NSBezierPath(roundedRect: NSRect(x: 214 * s, y: 350 * s, width: 596 * s, height: 400 * s), xRadius: 132 * s, yRadius: 132 * s)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 300 * s, y: 380 * s))
    tail.curve(to: NSPoint(x: 246 * s, y: 262 * s), controlPoint1: NSPoint(x: 304 * s, y: 320 * s), controlPoint2: NSPoint(x: 284 * s, y: 284 * s))
    tail.curve(to: NSPoint(x: 430 * s, y: 362 * s), controlPoint1: NSPoint(x: 330 * s, y: 270 * s), controlPoint2: NSPoint(x: 398 * s, y: 308 * s))
    tail.close()
    let bubble = NSBezierPath(cgPath: body.cgPath.union(tail.cgPath))

    NSGraphicsContext.saveGraphicsState()
    let bubbleShadow = NSShadow()
    bubbleShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    bubbleShadow.shadowBlurRadius = 36 * s
    bubbleShadow.shadowOffset = NSSize(width: 0, height: -14 * s)
    bubbleShadow.set()
    NSColor.white.setFill()
    bubble.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    bubble.addClip()
    NSGradient(colors: [rgb(255, 255, 255), rgb(226, 226, 232)])!.draw(in: NSRect(x: 200 * s, y: 250 * s, width: 624 * s, height: 510 * s), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Caption lines: the earlier line softer, the live line solid, then the live light.
    rgb(20, 20, 24, 0.28).setFill()
    NSBezierPath(roundedRect: NSRect(x: 300 * s, y: 588 * s, width: 424 * s, height: 58 * s), xRadius: 29 * s, yRadius: 29 * s).fill()
    rgb(20, 20, 24).setFill()
    NSBezierPath(roundedRect: NSRect(x: 300 * s, y: 462 * s, width: 286 * s, height: 58 * s), xRadius: 29 * s, yRadius: 29 * s).fill()
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = accent.withAlphaComponent(0.8)
    glow.shadowBlurRadius = 22 * s
    glow.set()
    accent.setFill()
    NSBezierPath(ovalIn: NSRect(x: 620 * s, y: 462 * s, width: 58 * s, height: 58 * s)).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()

    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2 * s, dy: 2 * s), xRadius: 184 * s, yRadius: 184 * s)
    rim.lineWidth = 3 * s
    NSColor.white.withAlphaComponent(0.14).setStroke()
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
}
