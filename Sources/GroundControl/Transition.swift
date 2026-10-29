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
    func run(direction: Int, _ change: @escaping () -> Void) {
        guard !busy, let timing = Settings.shared.switchSpeed.timing, CGPreflightScreenCaptureAccess(),
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
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
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

/// Squish with pictures: each window's snapshot covers it, the real windows jump to their new
/// sizes underneath (where slow apps can redraw unseen), the snapshots stretch into the new sizes
/// on the GPU, then step aside. Without Screen Recording it resizes the windows in steps instead.
final class StretchSquish {
    static let shared = StretchSquish()

    struct Move {
        let pid: pid_t
        let window: AXUIElement
        let from: CGRect
        let to: CGRect
    }

    private let panel: NSPanel
    private var busy = false

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
    }

    func run(_ moves: [Move], duration: Double, done: @escaping () -> Void) {
        let stepped = moves.map { WindowAnimator.Move(window: $0.window, from: $0.from, to: $0.to) }
        guard !busy, duration > 0, CGPreflightScreenCaptureAccess(), let screen = NSScreen.screens.first else {
            WindowAnimator.shared.animate(stepped, duration: duration, done: done)
            return
        }
        busy = true
        Task { @MainActor in
            let pictures = await Self.pictures(of: moves)
            guard pictures.count == moves.count else {
                busy = false
                WindowAnimator.shared.animate(stepped, duration: duration, done: done)
                return
            }
            // AX frames run down from the top-left of the screen, like this flipped view.
            let canvas = FlippedView(frame: CGRect(origin: .zero, size: screen.frame.size))
            var views: [(NSImageView, CGRect)] = []
            for (move, picture) in zip(moves, pictures) {
                let view = NSImageView(frame: move.from)
                view.image = picture
                view.imageScaling = .scaleAxesIndependently
                canvas.addSubview(view)
                views.append((view, move.to))
            }
            panel.contentView = canvas
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()

            moves.forEach { WindowMover.setFrame($0.window, $0.to) }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for (view, to) in views { view.animator().frame = to }
            }
            panel.orderOut(nil)
            panel.contentView = nil
            busy = false
            done()
        }
    }

    /// One picture per window, in order, matched by owner and position.
    @MainActor private static func pictures(of moves: [Move]) async -> [NSImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        var pictures: [NSImage] = []
        for move in moves {
            let candidates = content.windows.filter { $0.owningApplication?.processID == move.pid && $0.windowLayer == 0 }
            guard let window = candidates.min(by: { distance($0.frame, move.from) < distance($1.frame, move.from) }) else { return [] }
            let config = SCStreamConfiguration()
            let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config
            ) else { return [] }
            pictures.append(NSImage(cgImage: image, size: window.frame.size))
        }
        return pictures
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
