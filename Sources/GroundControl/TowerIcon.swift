import AppKit

enum TowerIcon {
    /// A control tower for the menu bar: an antenna, a glazed cab wider than its shaft, and the
    /// shaft flaring to the ground. A template, so it follows the menu bar's appearance.
    /// `stopped` adds a small no-entry sign: a ground stop is on.
    static func image(stopped: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let antenna = NSBezierPath()
            antenna.move(to: NSPoint(x: 9, y: 0.5))
            antenna.line(to: NSPoint(x: 9, y: 3.5))
            antenna.lineWidth = 1.2
            antenna.stroke()

            // Roof, then the cab, then a band of windows cut out of it.
            NSBezierPath(roundedRect: NSRect(x: 4.5, y: 3.5, width: 9, height: 1.6), xRadius: 0.6, yRadius: 0.6).fill()
            let cab = NSBezierPath()
            cab.move(to: NSPoint(x: 3.5, y: 5.1))
            cab.line(to: NSPoint(x: 14.5, y: 5.1))
            cab.line(to: NSPoint(x: 13, y: 9.2))
            cab.line(to: NSPoint(x: 5, y: 9.2))
            cab.close()
            cab.fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            for x in [5.6, 8.1, 10.6] {
                NSBezierPath(rect: NSRect(x: x, y: 6.1, width: 1.8, height: 2)).fill()
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            let shaft = NSBezierPath()
            shaft.move(to: NSPoint(x: 7.2, y: 9.2))
            shaft.line(to: NSPoint(x: 10.8, y: 9.2))
            shaft.line(to: NSPoint(x: 11.8, y: 16.2))
            shaft.line(to: NSPoint(x: 6.2, y: 16.2))
            shaft.close()
            shaft.fill()

            NSBezierPath(roundedRect: NSRect(x: 4, y: 16.2, width: 10, height: 1.5), xRadius: 0.5, yRadius: 0.5).fill()
            if stopped {
                // A no-entry sign in the corner, cut clear of the tower around it.
                let sign = NSRect(x: 11, y: 10, width: 7, height: 7)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: sign.insetBy(dx: -1, dy: -1)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: sign).fill()
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(rect: NSRect(x: sign.minX + 1.5, y: sign.midY - 0.8, width: sign.width - 3, height: 1.6)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = stopped ? "Ground Control, ground stop on" : "Ground Control"
        return image
    }
}

enum HangarIcon {
    /// A hangar for parked gates: an arched roof over an open door, on the ground. A template, so it
    /// follows the appearance like the airspace's other symbols.
    static func image(side: CGFloat = 14) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let s = side / 14
            NSColor.black.setFill()
            // The arched roof and walls, solid.
            let shell = NSBezierPath()
            shell.move(to: NSPoint(x: 0.5 * s, y: 12.5 * s))
            shell.line(to: NSPoint(x: 0.5 * s, y: 7 * s))
            shell.curve(to: NSPoint(x: 13.5 * s, y: 7 * s),
                        controlPoint1: NSPoint(x: 0.5 * s, y: 0.5 * s),
                        controlPoint2: NSPoint(x: 13.5 * s, y: 0.5 * s))
            shell.line(to: NSPoint(x: 13.5 * s, y: 12.5 * s))
            shell.close()
            shell.fill()
            // The open door, cut out of it.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(rect: NSRect(x: 3.5 * s, y: 7 * s, width: 7 * s, height: 5.5 * s)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            // Sliding door panels in the opening.
            for x in [5.6, 8.0] {
                NSBezierPath(rect: NSRect(x: x * s, y: 7 * s, width: 0.45 * s, height: 5.5 * s)).fill()
            }
            NSBezierPath(rect: NSRect(x: 0, y: 12.5 * s, width: 14 * s, height: 1.5 * s)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
