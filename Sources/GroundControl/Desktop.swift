import AppKit

/// Show Desktop: every app steps aside so the desktop can be used, and comes back on the second
/// press or as soon as the user switches to an app.
final class DesktopController {
    private(set) var showing = false
    private var hidden: [NSRunningApplication] = []
    private var finderWindows: [AXUIElement] = []
    private var observer: NSObjectProtocol?

    func toggle() {
        showing ? restore() : show()
    }

    private func show() {
        let own = Bundle.main.bundleIdentifier
        hidden = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.bundleIdentifier != own && $0.bundleIdentifier != Self.finder
        }
        // Accessibility can hide the app in front, which a background app can't ask macOS to do.
        for app in hidden {
            setHidden(app, true)
        }
        // Finder draws the desktop, so it stays; its open windows are minimized instead.
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: Self.finder).first {
            let windows: [AXUIElement] = AX.value(AXUIElementCreateApplication(finder.processIdentifier), kAXWindowsAttribute) ?? []
            finderWindows = windows.filter {
                AX.value($0, kAXSubroleAttribute) == kAXStandardWindowSubrole && AX.value($0, kAXMinimizedAttribute) != true
            }
            finderWindows.forEach { AXUIElementSetAttributeValue($0, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
            finder.activate()
        }
        showing = true
        log.notice("desktop shown")

        // Switching to an app ends it, as macOS's own Show Desktop does.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier != Self.finder, app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.restore(keepFront: app)
        }
    }

    private func restore(keepFront front: NSRunningApplication? = nil) {
        observer.map(NSWorkspace.shared.notificationCenter.removeObserver)
        observer = nil
        for app in hidden {
            setHidden(app, false)
        }
        finderWindows.forEach { AXUIElementSetAttributeValue($0, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        front?.activate()
        hidden = []
        finderWindows = []
        showing = false
        log.notice("desktop restored")
    }

    private func setHidden(_ app: NSRunningApplication, _ value: Bool) {
        if AXIsProcessTrusted() {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXHiddenAttribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
        } else if value {
            app.hide()
        } else {
            app.unhide()
        }
    }

    private static let finder = "com.apple.finder"
}
