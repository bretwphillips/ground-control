import AppKit

/// Puts the cursor back where the user was typing when an app is brought forward by a shortcut,
/// swipe or gate: the text field or editor it had when they left it, or failing that its main
/// text area. Apps restore focus themselves, but only to wherever it last was, which may be a
/// sidebar or a list.
final class TypingFocus {
    static let shared = TypingFocus()

    /// The text element that had focus in each app when the user left it.
    private var remembered: [String: AXUIElement] = [:]
    private var observers: [NSObjectProtocol] = []

    private static let textRoles: Set<String> = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole]

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.remember(app)
        })
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Self.exposeIfElectron(app)
        })
        NSWorkspace.shared.runningApplications.forEach(Self.exposeIfElectron)
    }

    /// Called just after an app is brought forward by Ground Control.
    func restore(_ id: String) {
        // Activation takes a moment to land; focus set before then is overwritten.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, AXIsProcessTrusted(),
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                  NSWorkspace.shared.frontmostApplication == app else { return }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            if let focused: AXUIElement = AX.value(element, kAXFocusedUIElementAttribute), Self.isText(focused) { return }
            let target = remembered[id].flatMap { Self.isText($0) ? $0 : nil } ?? Self.mainTextArea(of: element)
            guard let target else {
                log.notice("typing focus: nothing to type in for \(id, privacy: .public)")
                return
            }
            let result = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            log.notice("typing focus: \(id, privacy: .public) \(self.remembered[id] == nil ? "main text area" : "where you were", privacy: .public) (\(result.rawValue))")
        }
    }

    private func remember(_ app: NSRunningApplication) {
        guard AXIsProcessTrusted(), let id = app.bundleIdentifier else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        if let focused: AXUIElement = AX.value(element, kAXFocusedUIElementAttribute), Self.isText(focused) {
            remembered[id] = focused
        }
    }

    /// A text area or field that's still there to type in.
    private static func isText(_ element: AXUIElement) -> Bool {
        guard let role: String = AX.value(element, kAXRoleAttribute) else { return false }
        return textRoles.contains(role) && AX.value(element, kAXEnabledAttribute) != false
    }

    /// The biggest text area in the app's focused window: the terminal itself, a chat's message
    /// box. Searches a bounded part of the tree, since some apps' trees are huge.
    private static func mainTextArea(of app: AXUIElement) -> AXUIElement? {
        guard let window: AXUIElement = AX.value(app, kAXFocusedWindowAttribute) ?? AX.value(app, kAXMainWindowAttribute) else { return nil }
        var best: (element: AXUIElement, area: CGFloat)?
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let element = queue.removeFirst()
            visited += 1
            if isText(element), let size: AXValue = AX.value(element, kAXSizeAttribute) {
                var extent = CGSize.zero
                AXValueGetValue(size, .cgSize, &extent)
                let area = extent.width * extent.height
                if area > (best?.area ?? 0) { best = (element, area) }
            }
            queue += AX.children(element)
        }
        return best?.element
    }

    /// Electron apps (Slack, VS Code) keep their contents hidden from Accessibility until an
    /// assistive app asks for them, as screen readers do.
    private static func exposeIfElectron(_ app: NSRunningApplication) {
        guard AXIsProcessTrusted(), app.activationPolicy == .regular, let bundle = app.bundleURL,
              FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
