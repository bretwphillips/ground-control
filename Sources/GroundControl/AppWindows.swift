import ScreenCaptureKit

enum AppWindows {
    /// The window that stands for an app in previews.
    static func main(of pid: pid_t) async -> SCWindow? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            return nil
        }
        return main(of: pid, in: content)
    }

    static func main(of pid: pid_t, in content: SCShareableContent) -> SCWindow? {
        content.windows
            .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 100 && $0.frame.height > 100 }
            .max { rank($0) < rank($1) }
    }

    /// Some apps (VS Code) keep hidden helper windows; a titled one the user can see is the real thing.
    private static func rank(_ window: SCWindow) -> (Int, Int, CGFloat) {
        (window.isOnScreen ? 1 : 0, (window.title ?? "").isEmpty ? 0 : 1, window.frame.width * window.frame.height)
    }
}
