import AppKit
import ScreenCaptureKit

/// Small pictures of each app's main window, for the large strip. Needs Screen Recording.
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
        guard settings.size == .large, permissions.screenRecording, !busy else { return }
        busy = true
        // Every app, since the strip offers them all while a gate is being built.
        let pids = tracker.allApps.map(\.pid)
        Task { @MainActor in
            defer { self.busy = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
                return
            }
            var latest = self.images.filter { pids.contains($0.key) }
            for pid in pids {
                // Hidden and minimized windows aren't drawn, and capturing them can hang; their last
                // picture stays.
                guard let window = AppWindows.main(of: pid, in: content), window.isOnScreen else { continue }
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
