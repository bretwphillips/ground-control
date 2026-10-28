import AppKit

/// Show Desktop: every app steps aside so the desktop can be used, and comes back on the second
/// press or as soon as the user switches to an app.
final class DesktopController {
    private(set) var showing = false
    private var hidden: [NSRunningApplication] = []
    private var finderWindows: [AXUIElement] = []
    private var observer: NSObjectProtocol?
    /// Reopens the gate that was open, with the given app in front, and says whether there was
    /// one. Set by the gate controller.
    var reopenGate: ((String?) -> Bool)?

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

    /// Back to where things were: the open gate if there was one, with apps outside it left
    /// hidden; otherwise everything that was showing. Switching to an app outside the gate brings
    /// just that app back.
    private func restore(keepFront front: NSRunningApplication? = nil) {
        observer.map(NSWorkspace.shared.notificationCenter.removeObserver)
        observer = nil
        showing = false
        finderWindows.forEach { AXUIElementSetAttributeValue($0, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        if let front {
            if reopenGate?(front.bundleIdentifier) != true {
                setHidden(front, false)
                front.activate()
            }
        } else if reopenGate?(nil) != true {
            hidden.forEach { setHidden($0, false) }
        }
        hidden = []
        finderWindows = []
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
