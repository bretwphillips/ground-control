// Draws the app icon: a control tower in a dusk sky with a plane circling it.
//   swift scripts/make-icon.swift Resources/AppIcon.icns [preview.png]
import AppKit

func draw(_ side: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
        let s = side / 1024
        // macOS app shape: a rounded square inset from the canvas.
        let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let shape = NSBezierPath(roundedRect: plate, xRadius: 185 * s, yRadius: 185 * s)

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.shadowBlurRadius = 24 * s
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        NSGraphicsContext.current?.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [
            NSColor(srgbRed: 0.98, green: 0.62, blue: 0.38, alpha: 1),
            NSColor(srgbRed: 0.42, green: 0.36, blue: 0.70, alpha: 1),
            NSColor(srgbRed: 0.07, green: 0.12, blue: 0.30, alpha: 1),
        ], atLocations: [0, 0.35, 1], colorSpace: .sRGB)!.draw(in: plate, angle: 90)

        // Ground.
        NSColor(srgbRed: 0.05, green: 0.08, blue: 0.18, alpha: 1).setFill()
        NSRect(x: plate.minX, y: plate.minY, width: plate.width, height: 150 * s).fill()

        // The circling plane's path: its far half behind the tower, its near half in front.
        let orbit = NSRect(x: 230 * s, y: 560 * s, width: 564 * s, height: 190 * s)
        let path = NSBezierPath(ovalIn: orbit)
        path.lineWidth = 7 * s
        path.setLineDash([22 * s, 18 * s], count: 2, phase: 0)
        let strokeHalf = { (near: Bool) in
            NSGraphicsContext.current?.saveGraphicsState()
            NSRect(x: orbit.minX - 10 * s, y: near ? orbit.minY - 10 * s : orbit.midY, width: orbit.width + 20 * s, height: orbit.height / 2 + 10 * s).clip()
            // Amber in front, so it shows across the white tower; faint white behind.
            (near ? NSColor(srgbRed: 1, green: 0.78, blue: 0.35, alpha: 1) : NSColor.white.withAlphaComponent(0.4)).setStroke()
            path.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        strokeHalf(false)

        // The tower, white, with lit windows.
        let tower = NSColor(white: 0.97, alpha: 1)
        tower.setFill()
        NSRect(x: 505 * s, y: 760 * s, width: 14 * s, height: 70 * s).fill()
        NSBezierPath(roundedRect: NSRect(x: 395 * s, y: 730 * s, width: 234 * s, height: 36 * s), xRadius: 12 * s, yRadius: 12 * s).fill()
        let cab = NSBezierPath()
        cab.move(to: NSPoint(x: 370 * s, y: 730 * s))
        cab.line(to: NSPoint(x: 654 * s, y: 730 * s))
        cab.line(to: NSPoint(x: 616 * s, y: 620 * s))
        cab.line(to: NSPoint(x: 408 * s, y: 620 * s))
        cab.close()
        cab.fill()
        NSColor(srgbRed: 1, green: 0.78, blue: 0.35, alpha: 1).setFill()
        for x in [425.0, 488, 551] {
            NSRect(x: x * s, y: 646 * s, width: 48 * s, height: 58 * s).fill()
        }
        tower.setFill()
        let shaft = NSBezierPath()
        shaft.move(to: NSPoint(x: 462 * s, y: 620 * s))
        shaft.line(to: NSPoint(x: 562 * s, y: 620 * s))
        shaft.line(to: NSPoint(x: 600 * s, y: 250 * s))
        shaft.line(to: NSPoint(x: 424 * s, y: 250 * s))
        shaft.close()
        shaft.fill()
        NSBezierPath(roundedRect: NSRect(x: 360 * s, y: 236 * s, width: 304 * s, height: 30 * s), xRadius: 10 * s, yRadius: 10 * s).fill()

        strokeHalf(true)

        // The plane, on the near side of its loop.
        let config = NSImage.SymbolConfiguration(pointSize: 104 * s, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        if let plane = NSImage(systemSymbolName: "airplane", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = plane.size
            plane.draw(in: NSRect(x: 700 * s - size.width / 2, y: 580 * s - size.height / 2, width: size.width, height: size.height))
        }
        NSGraphicsContext.current?.restoreGraphicsState()
        return true
    }
}

func png(_ image: NSImage, _ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let arguments = CommandLine.arguments
let icns = URL(fileURLWithPath: arguments[1])
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! png(draw(CGFloat(points * scale)), points * scale).write(to: set.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set.path, "-o", icns.path]
try! iconutil.run()
iconutil.waitUntilExit()
if arguments.count > 2 {
    try! png(draw(1024), 1024).write(to: URL(fileURLWithPath: arguments[2]))
}
