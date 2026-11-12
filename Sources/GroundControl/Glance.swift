import AppKit
import ScreenCaptureKit

/// A look at another gate without going there, like turning to a second screen: its windows slide
/// in, live, over the desktop picture, and slide back out, leaving focus and layout as they were.
/// Going on through opens the gate for real. Needs Screen Recording; without it, only going through
/// does anything.
final class Glance {
    private let gates: GateController
    private let previews: Previews
    private let panel: NSPanel
    /// What slides: the desktop picture and the gate's windows on it.
    private let slide = CALayer()
    private var windows: [String: CALayer] = [:]
    private(set) var gate: Gate?
    private var direction = 1
    private var progress: CGFloat = 0
    private var visible = false
    /// Changes with every glance, so an earlier one's captures stand down.
    private var session = UUID()
    /// The glance whose pictures are still live. Going through freezes them: the real apps
    /// coming forward underneath redraw blank for a moment, which a capture would show.
    private var feed = UUID()
    private let desktop = CALayer()

    init(gates: GateController, previews: Previews) {
        self.gates = gates
        self.previews = previews
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // With the transition: under the airspace, over every window.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(slide)
        panel.contentView = view
        slide.shadowColor = NSColor.black.cgColor
        slide.shadowOpacity = 0.5
        slide.shadowRadius = 24
    }

    /// Starts looking at `gate`, which lies `direction` (-1 or 1) along the strip from the open one.
    func begin(_ gate: Gate, direction: Int) {
        end(commit: false, animated: false)
        guard gate.id != gates.store.current else { return }
        self.gate = gate
        self.direction = direction == 0 ? 1 : direction
        progress = 0
        session = UUID()
        feed = session
        guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.screens.first else { return }
        visible = true
        build(gate, on: screen)
        panel.setFrame(screen.frame, display: false)
        place(animated: false)
        panel.orderFrontRegardless()
        watch(session)
    }

    /// How far in the gate has come, from 0 (not at all) to 1 (covering the screen).
    func move(to progress: CGFloat, animated: Bool = false) {
        guard gate != nil else { return }
        self.progress = min(max(progress, 0), 1)
        place(animated: animated, duration: 0.2)
    }

    /// Lets go: back out, or on through to the gate itself.
    func end(commit: Bool, animated: Bool = true) {
        guard let gate else { return }
        self.gate = nil
        let session = self.session
        guard visible else {
            if commit { gates.switchTo(gate, direction: direction) }
            return
        }
        visible = false
        guard animated else {
            hide()
            return
        }
        progress = commit ? 1 : 0
        place(animated: true, duration: commit ? 0.12 : 0.2) { [weak self] in
            guard let self, self.session == session else { return }
            guard commit else {
                hide()
                return
            }
            // The real gate opens under the picture of it, which goes once the apps have come
            // forward and redrawn. Fading would show them blink through it, and the windows'
            // bars change colour as they take focus; a cut is like clicking into them.
            feed = UUID()
            gates.open(gate)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.session == session else { return }
                hide()
            }
        }
    }

    private func hide() {
        session = UUID()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    /// The desktop picture with the gate's windows where opening it would put them, first from
    /// the last previews, then live.
    private func build(_ gate: Gate, on screen: NSScreen) {
        // Set up where it is; animating from where the last glance ended would flash it on screen.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        slide.removeAllAnimations()
        slide.sublayers?.forEach { $0.removeFromSuperlayer() }
        windows = [:]
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        slide.frame = bounds

        desktop.contents = nil
        desktop.frame = bounds
        desktop.contentsGravity = .resizeAspectFill
        desktop.masksToBounds = true
        desktop.backgroundColor = NSColor.windowBackgroundColor.cgColor
        if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) {
            desktop.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        slide.addSublayer(desktop)

        for (id, _, frame) in gates.frames(of: gate) {
            let layer = CALayer()
            // AX frames run down from the top of the screen; layers run up from the bottom.
            layer.frame = CGRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height)
            layer.contentsGravity = .resize
            layer.cornerRadius = 10
            layer.masksToBounds = true
            layer.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
            if let pid = app?.processIdentifier, let image = previews.images[pid] {
                layer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            } else {
                // Not running, or never pictured: its icon stands in.
                let icon = CALayer()
                icon.frame = CGRect(x: frame.width / 2 - 48, y: frame.height / 2 - 48, width: 96, height: 96)
                icon.contents = (app?.icon ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map {
                    NSWorkspace.shared.icon(forFile: $0.path)
                })?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                layer.addSublayer(icon)
            }
            slide.addSublayer(layer)
            windows[id] = layer
        }
    }

    /// Slides in from the gate's side; with Reduce Motion it fades in where it stands.
    private func place(animated: Bool, duration: Double = 0, done: (() -> Void)? = nil) {
        let width = slide.bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock(done)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            slide.position = CGPoint(x: width / 2, y: slide.bounds.height / 2)
            slide.opacity = Float(progress)
        } else {
            slide.position = CGPoint(x: width / 2 + CGFloat(direction) * width * (1 - progress), y: slide.bounds.height / 2)
            slide.opacity = 1
        }
        CATransaction.commit()
    }

    /// Keeps the windows live for as long as the glance lasts, over the desktop as it is now,
    /// icons and all.
    private func watch(_ session: UUID) {
        guard let gate else { return }
        let frames = gates.frames(of: gate)
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        Task { @MainActor [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
            if let display = content.displays.first(where: { $0.frame.origin == .zero }) ?? content.displays.first {
                // The wallpaper and desktop icons sit below every window.
                let below = content.windows.filter { $0.windowLayer < 0 && $0.isOnScreen }
                let config = SCStreamConfiguration()
                config.width = Int(display.frame.width * scale)
                config.height = Int(display.frame.height * scale)
                config.showsCursor = false
                if let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, including: below), configuration: config
                ), let self, self.feed == session {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.desktop.contents = image
                    CATransaction.commit()
                }
            }
            var targets: [(id: String, filter: SCContentFilter, config: SCStreamConfiguration)] = []
            for (id, title, frame) in frames {
                guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier else { continue }
                let candidates = AppWindows.candidates(of: pid, in: content)
                guard let window = candidates.first(where: { title != nil && $0.title == title }) ?? candidates.first else { continue }
                let config = SCStreamConfiguration()
                config.width = Int(frame.width * scale)
                config.height = Int(frame.height * scale)
                config.showsCursor = false
                targets.append((id, SCContentFilter(desktopIndependentWindow: window), config))
            }
            while let self, self.feed == session {
                for target in targets {
                    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: target.filter, configuration: target.config),
                          self.feed == session else { continue }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.windows[target.id]?.sublayers?.forEach { $0.removeFromSuperlayer() }
                    // A see-through window (D-Pet) shows the desktop behind it, as it does for real.
                    self.windows[target.id]?.backgroundColor = nil
                    self.windows[target.id]?.contents = image
                    CATransaction.commit()
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
