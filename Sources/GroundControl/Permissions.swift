import AppKit

enum Permission: String {
    case accessibility, screenRecording

    var isGranted: Bool {
        switch self {
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }

    /// macOS only shows its own prompt once, so later requests open the settings pane instead.
    func request() {
        let asked = "asked.\(rawValue)"
        guard !UserDefaults.standard.bool(forKey: asked) else {
            NSWorkspace.shared.open(settingsURL)
            return
        }
        UserDefaults.standard.set(true, forKey: asked)
        switch self {
        case .accessibility: AX.requestTrust()
        case .screenRecording: CGRequestScreenCaptureAccess()
        }
    }

    private var settingsURL: URL {
        let pane = self == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// Every feature works without these; each one only adds to what the strip can do.
final class Permissions: ObservableObject {
    @Published private(set) var accessibility = Permission.accessibility.isGranted
    @Published private(set) var screenRecording = Permission.screenRecording.isGranted

    private var timer: Timer?

    init() {
        log.notice("launched, accessibility: \(self.accessibility), screen recording: \(self.screenRecording)")
        // macOS posts nothing when a permission changes in System Settings.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let latest = (Permission.accessibility.isGranted, Permission.screenRecording.isGranted)
        if latest.0 != accessibility {
            accessibility = latest.0
            log.notice("accessibility: \(latest.0)")
        }
        if latest.1 != screenRecording {
            screenRecording = latest.1
            log.notice("screen recording: \(latest.1)")
        }
    }
}
