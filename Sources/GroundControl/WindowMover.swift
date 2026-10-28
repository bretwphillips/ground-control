import AppKit

enum WindowMover {
    /// Brings the app forward and fills `frame` (AX coordinates) with its main window.
    static func land(_ app: StripApp, in frame: CGRect) {
        NSRunningApplication(processIdentifier: app.pid)?.activate()

        let element = AXUIElementCreateApplication(app.pid)
        let windows: [AXUIElement] = AX.value(element, kAXWindowsAttribute) ?? []
        guard let window: AXUIElement = AX.value(element, kAXMainWindowAttribute) ?? windows.first else { return }
        setFrame(window, frame)
    }

    /// Pulls every standard window out from under the strip, keeping the part already on the runway.
    /// Both rects are in AX coordinates.
    static func clear(_ strip: CGRect, into runway: CGRect, pids: [pid_t]) {
        for pid in pids {
            for window in standardWindows(of: pid) {
                guard let frame = frame(of: window), frame.intersects(strip) else { continue }
                let kept = frame.intersection(runway)
                let fits = kept.width >= 200 && kept.height >= 150
                let size = CGSize(width: min(frame.width, runway.width), height: min(frame.height, runway.height))
                setFrame(window, fits ? kept : CGRect(origin: runway.origin, size: size))
            }
        }
    }

    /// AppKit measures from the bottom-left of the primary screen, AX from its top-left.
    static func axFrame(_ frame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func standardWindows(of pid: pid_t) -> [AXUIElement] {
        let windows: [AXUIElement] = AX.value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
        return windows.filter { window in
            AX.value(window, kAXSubroleAttribute) == kAXStandardWindowSubrole
                && AX.value(window, kAXMinimizedAttribute) != true
        }
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let position: AXValue = AX.value(window, kAXPositionAttribute),
              let size: AXValue = AX.value(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    private static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        // Moved again after resizing: a window can't shrink past the screen edge it's pinned to.
        AX.set(window, kAXPositionAttribute, AXValueCreate(.cgPoint, &origin))
        AX.set(window, kAXSizeAttribute, AXValueCreate(.cgSize, &size))
        AX.set(window, kAXPositionAttribute, AXValueCreate(.cgPoint, &origin))
    }
}
