import AppKit
import ScreenCaptureKit

/// Small pictures of each app's biggest window, for the large strip. Needs Screen Recording.
final class Previews: ObservableObject {
    @Published private(set) var images: [pid_t: NSImage] = [:]

    private let tracker: AppTracker
    private let settings: Settings
    private let permissions: Permissions
    private var busy = false
    private var timer: Timer?

    init(tracker: AppTracker, settings: Settings, permissions: Permissions) {
        self.tracker = tracker
        self.settings = settings
        self.permissions = permissions
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        guard settings.size == .large, settings.previews, permissions.screenRecording, !busy else { return }
        busy = true
        let pids = tracker.apps.map(\.pid)
        Task { @MainActor in
            defer { self.busy = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
                return
            }
            var latest = self.images.filter { pids.contains($0.key) }
            for pid in pids {
                let windows = content.windows.filter {
                    $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 100 && $0.frame.height > 100
                }
                guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                    continue
                }
                let config = SCStreamConfiguration()
                let scale = 300 / window.frame.width
                config.width = Int(window.frame.width * scale)
                config.height = Int(window.frame.height * scale)
                config.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: window)
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    latest[pid] = NSImage(cgImage: image, size: .zero)
                }
            }
            self.images = latest
        }
    }
}
