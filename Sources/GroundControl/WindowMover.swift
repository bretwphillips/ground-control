import AppKit

enum WindowMover {
    /// Brings the app forward and fills `frame` (AX coordinates) with its main window.
    static func land(_ app: StripApp, in frame: CGRect) {
        NSRunningApplication(processIdentifier: app.pid)?.activate()
        guard let window = mainWindow(of: app.pid) else { return }
        setFrame(window, frame)
    }

    /// Pulls every standard window out from under the strip, keeping the part already on the runway.
    /// Both rects are in AX coordinates.
    static func clear(_ strip: CGRect, into runway: CGRect, pids: [pid_t]) {
        for pid in pids {
            for window in standardWindows(of: pid) {
                // Full-screen windows have a desktop of their own, where the strip doesn't show.
                guard AX.value(window, "AXFullScreen") != true,
                      let frame = frame(of: window), frame.intersects(strip) else { continue }
                let kept = frame.intersection(runway)
                let fits = kept.width >= 200 && kept.height >= 150
                let size = CGSize(width: min(frame.width, runway.width), height: min(frame.height, runway.height))
                let target = fits ? kept : CGRect(origin: runway.origin, size: size)
                log.notice("pid \(pid): \(String(describing: frame)) -> \(String(describing: target))")
                setFrame(window, target)
            }
        }
    }

    static func mainWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        // The main window can be the one sitting minimized in the Dock.
        if let main: AXUIElement = AX.value(app, kAXMainWindowAttribute), AX.value(main, kAXMinimizedAttribute) != true {
            return main
        }
        return standardWindows(of: pid).first
    }

    static func minimizedWindow(of pid: pid_t) -> AXUIElement? {
        let windows: [AXUIElement] = AX.value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
        return windows.first { AX.value($0, kAXMinimizedAttribute) == true }
    }

    static func frontWindow() -> AXUIElement? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return AX.value(AXUIElementCreateApplication(front.processIdentifier), kAXFocusedWindowAttribute)
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let position: AXValue = AX.value(window, kAXPositionAttribute),
              let size: AXValue = AX.value(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        // Moved again after resizing: a window can't shrink past the screen edge it's pinned to.
        AX.set(window, kAXPositionAttribute, AXValueCreate(.cgPoint, &origin))
        AX.set(window, kAXSizeAttribute, AXValueCreate(.cgSize, &size))
        AX.set(window, kAXPositionAttribute, AXValueCreate(.cgPoint, &origin))
    }

    /// Whether the app has a window on the desktop in view. The on-screen window list only covers
    /// the current desktop, so a running, unhidden app missing from it lives on another.
    static func isOnThisDesktop(_ pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        return windows.contains { window in
            window[kCGWindowOwnerPID as String] as? pid_t == pid
                && window[kCGWindowLayer as String] as? Int == 0
                && ((window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.height ?? 0) > 100
        }
    }

    /// Whether the app has a real window on some desktop other than the one in view.
    static func hasWindowElsewhere(_ pid: pid_t) -> Bool {
        guard !isOnThisDesktop(pid),
              let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains { window in
            window[kCGWindowOwnerPID as String] as? pid_t == pid
                && window[kCGWindowLayer as String] as? Int == 0
                && ((window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.height ?? 0) > 100
        }
    }

    /// AppKit measures from the bottom-left of the primary screen, AX from its top-left.
    static func axFrame(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private static func standardWindows(of pid: pid_t) -> [AXUIElement] {
        let windows: [AXUIElement] = AX.value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
        return windows.filter { window in
            AX.value(window, kAXSubroleAttribute) == kAXStandardWindowSubrole
                && AX.value(window, kAXMinimizedAttribute) != true
        }
    }
}
