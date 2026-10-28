import AppKit

enum WindowMover {
    /// Brings the app forward and fills `frame` (AX coordinates) with its main window.
    static func land(_ app: StripApp, in frame: CGRect) {
        NSRunningApplication(processIdentifier: app.pid)?.activate()

        let element = AXUIElementCreateApplication(app.pid)
        let windows: [AXUIElement] = AX.value(element, kAXWindowsAttribute) ?? []
        guard let window: AXUIElement = AX.value(element, kAXMainWindowAttribute) ?? windows.first else { return }

        var origin = frame.origin
        var size = frame.size
        AX.set(window, kAXPositionAttribute, AXValueCreate(.cgPoint, &origin))
        AX.set(window, kAXSizeAttribute, AXValueCreate(.cgSize, &size))
    }

    /// AppKit measures from the bottom-left of the primary screen, AX from its top-left.
    static func axFrame(_ frame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
