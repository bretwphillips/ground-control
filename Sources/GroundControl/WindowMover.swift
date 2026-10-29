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

    /// `exact: false` skips the second move, for the in-between steps of an animation.
    static func setFrame(_ window: AXUIElement, _ frame: CGRect, exact: Bool = true) {
        var origin = frame.origin
        var size = frame.size
        // Moved again after resizing: a window can't shrink past the screen edge it's pinned to.
        AX.set(window, kAXPositionAttribute, AXValueCreate(.cgPoint, &origin))
        AX.set(window, kAXSizeAttribute, AXValueCreate(.cgSize, &size))
        if exact { AX.set(window, kAXPositionAttribute, AXValueCreate(.cgPoint, &origin)) }
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

    static func axPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// The inverse of `axFrame`.
    static func appKitFrame(_ frame: CGRect) -> CGRect {
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

/// Moves windows to new frames in small steps, so a resize is seen as growing and shrinking
/// rather than a jump.
final class WindowAnimator {
    static let shared = WindowAnimator()

    struct Move {
        let window: AXUIElement
        let from: CGRect
        let to: CGRect
    }

    private var timer: Timer?

    func animate(_ moves: [Move], duration: Double, done: (() -> Void)? = nil) {
        timer?.invalidate()
        guard duration > 0 else {
            moves.forEach { WindowMover.setFrame($0.window, $0.to) }
            done?()
            return
        }
        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
            let progress = min(Date().timeIntervalSince(start) / duration, 1)
            // Eases in and out, so the change starts and settles gently.
            let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
            for move in moves {
                WindowMover.setFrame(move.window, Self.blend(move.from, move.to, eased), exact: false)
            }
            guard progress >= 1 else { return }
            timer.invalidate()
            moves.forEach { WindowMover.setFrame($0.window, $0.to) }
            done?()
        }
    }

    private static func blend(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        ).integral
    }
}
