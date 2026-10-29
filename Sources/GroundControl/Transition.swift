import AppKit
import ScreenCaptureKit

/// Smooths switching gates. Moving other apps' windows frame by frame stutters, so instead a
/// snapshot of the screen covers it, the gate switches underneath, and the snapshot slides away in
/// the direction of travel while fading, like moving between desktops. With Reduce Motion it only
/// fades; set to Instant, or without Screen Recording, the switch is immediate.
final class Transition {
    static let shared = Transition()

    private let panel: NSPanel
    private var busy = false

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Just under the airspace and seam handles, which stay crisp on top; above other windows.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
    }

    /// `direction` is -1 or 1 for a gate to the left or right, 0 for one picked directly.
    /// `squish` is a resize within a gate: no slide, a longer settle and a gentler fade.
    func run(direction: Int, squish: Bool = false, _ change: @escaping () -> Void) {
        let speed = Settings.shared.switchSpeed
        guard !busy, let timing = squish ? speed.squishTiming : speed.timing, CGPreflightScreenCaptureAccess(),
              let screen = NSScreen.screens.first else {
            change()
            return
        }
        busy = true
        Task { @MainActor in
            guard let snapshot = await Self.snapshot(of: screen) else {
                busy = false
                change()
                return
            }
            let view = NSImageView(image: snapshot)
            view.imageScaling = .scaleAxesIndependently
            panel.contentView = view
            panel.alphaValue = 1
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            change()

            // A moment for the windows underneath to settle before the snapshot moves off them.
            try? await Task.sleep(for: .seconds(timing.settle))
            let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || direction == 0
            var away = screen.frame
            away.origin.x -= CGFloat(direction) * screen.frame.width * 0.25
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = timing.slide
                context.timingFunction = CAMediaTimingFunction(name: squish ? .easeInEaseOut : .easeOut)
                panel.animator().alphaValue = 0
                if !still { panel.animator().setFrame(away, display: true) }
            }
            panel.orderOut(nil)
            panel.contentView = nil
            busy = false
        }
    }

    /// The screen as it is now, without Ground Control's own panels, so the airspace stays crisp
    /// on top while the snapshot moves.
    @MainActor private static func snapshot(of screen: NSScreen) async -> NSImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.frame.origin == .zero }) ?? content.displays.first else { return nil }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return NSImage(cgImage: image, size: screen.frame.size)
    }
}
