import AppKit
import ScreenCaptureKit

/// Small pictures of each app's main window, for large tiles and hover peeks. Needs Screen Recording.
final class Previews: ObservableObject {
    @Published private(set) var images: [pid_t: NSImage] = [:]
    /// A terminal that was busy for a while has gone still.
    var onFinished: ((pid_t) -> Void)?

    /// Terminals whose window is watched for going quiet.
    static let terminals: Set<String> = [
        "com.googlecode.iterm2", "com.apple.Terminal", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
    ]
    /// Per terminal: a tiny greyscale copy of its last picture, when it first changed after being
    /// still, and when it last changed.
    private var activity: [pid_t: (thumb: [UInt8], busySince: Date?, lastChange: Date)] = [:]

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
        // Every size needs them now: the hover peek shows one at any strip size.
        guard permissions.screenRecording, !busy else { return }
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
                // A hidden app's likeliest window can refuse capture (VS Code); the next one may not.
                for window in AppWindows.candidates(of: pid, in: content).prefix(3) {
                    let config = SCStreamConfiguration()
                    let scale = 640 / window.frame.width
                    config.width = Int(window.frame.width * scale)
                    config.height = Int(window.frame.height * scale)
                    config.showsCursor = false
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                        latest[pid] = NSImage(cgImage: image, size: .zero)
                        self.watch(pid, image)
                        break
                    }
                }
            }
            self.images = latest
        }
    }

    /// A terminal that changed for at least 20 seconds and then stayed still for 8 has finished
    /// what it was doing. A blinking text cursor is a few pixels and doesn't count as change.
    private func watch(_ pid: pid_t, _ image: CGImage) {
        guard let id = tracker.allApps.first(where: { $0.pid == pid })?.id, Self.terminals.contains(id),
              let thumb = Self.thumbnail(image) else { return }
        let now = Date()
        guard var state = activity[pid] else {
            activity[pid] = (thumb, nil, now)
            return
        }
        let changed = zip(state.thumb, thumb).filter { abs(Int($0) - Int($1)) > 12 }.count > 3
        if changed {
            if state.busySince == nil { state.busySince = now }
            state.lastChange = now
        } else if let busySince = state.busySince, now.timeIntervalSince(state.lastChange) > 8 {
            if state.lastChange.timeIntervalSince(busySince) > 20 { onFinished?(pid) }
            state.busySince = nil
        }
        state.thumb = thumb
        activity[pid] = state
    }

    private static func thumbnail(_ image: CGImage) -> [UInt8]? {
        let width = 64, height = 40
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }
}
