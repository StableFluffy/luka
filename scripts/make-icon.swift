// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 186 * s, yRadius: 186 * s)

    // Drop shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 30 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    rgb(40, 30, 110).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background: deep indigo into violet, with a warm glow low on the right.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [rgb(34, 42, 140), rgb(88, 58, 214), rgb(150, 86, 240)])!.draw(in: tile, angle: -65)
    let glow = NSGradient(colors: [rgb(255, 140, 110, 0.55), rgb(255, 140, 110, 0)])!
    glow.draw(fromCenter: NSPoint(x: 800 * s, y: 190 * s), radius: 0, toCenter: NSPoint(x: 800 * s, y: 190 * s), radius: 520 * s, options: [])
    let sheen = NSGradient(colors: [.white.withAlphaComponent(0.22), .white.withAlphaComponent(0)])!
    sheen.draw(in: NSRect(x: tile.minX, y: tile.midY + 40 * s, width: tile.width, height: tile.height / 2 - 40 * s), angle: -90)

    // Frosted speech bubble.
    let bubbleRect = NSRect(x: 205 * s, y: 330 * s, width: 614 * s, height: 420 * s)
    let body = NSBezierPath(roundedRect: bubbleRect, xRadius: 120 * s, yRadius: 120 * s)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 300 * s, y: 350 * s))
    tail.curve(to: NSPoint(x: 250 * s, y: 238 * s), controlPoint1: NSPoint(x: 300 * s, y: 300 * s), controlPoint2: NSPoint(x: 285 * s, y: 262 * s))
    tail.curve(to: NSPoint(x: 420 * s, y: 340 * s), controlPoint1: NSPoint(x: 330 * s, y: 250 * s), controlPoint2: NSPoint(x: 390 * s, y: 290 * s))
    tail.close()
    let bubble = NSBezierPath(cgPath: body.cgPath.union(tail.cgPath))

    NSGraphicsContext.saveGraphicsState()
    let bubbleShadow = NSShadow()
    bubbleShadow.shadowColor = rgb(20, 10, 80, 0.35)
    bubbleShadow.shadowBlurRadius = 40 * s
    bubbleShadow.shadowOffset = NSSize(width: 0, height: -16 * s)
    bubbleShadow.set()
    NSColor.white.withAlphaComponent(0.2).setFill()
    bubble.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.55).setStroke()
    bubble.lineWidth = 4 * s
    bubble.stroke()

    // Caption lines: an earlier line, and the live one with a warm dot.
    NSColor.white.withAlphaComponent(0.6).setFill()
    NSBezierPath(roundedRect: NSRect(x: 290 * s, y: 575 * s, width: 444 * s, height: 64 * s), xRadius: 32 * s, yRadius: 32 * s).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 290 * s, y: 445 * s, width: 300 * s, height: 64 * s), xRadius: 32 * s, yRadius: 32 * s).fill()
    NSGraphicsContext.saveGraphicsState()
    let dotGlow = NSShadow()
    dotGlow.shadowColor = rgb(255, 150, 70, 0.9)
    dotGlow.shadowBlurRadius = 26 * s
    dotGlow.set()
    rgb(255, 160, 80).setFill()
    NSBezierPath(ovalIn: NSRect(x: 628 * s, y: 445 * s, width: 64 * s, height: 64 * s)).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()

    // Rim light around the tile.
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2 * s, dy: 2 * s), xRadius: 184 * s, yRadius: 184 * s)
    rim.lineWidth = 3 * s
    NSColor.white.withAlphaComponent(0.28).setStroke()
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
