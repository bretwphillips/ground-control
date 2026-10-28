import AppKit
import Combine
import SwiftUI

/// Floats over every space without ever taking focus from the landed app.
final class StripPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
    }

    override var canBecomeKey: Bool { false }
}

final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class StripController {
    private let panel = StripPanel()
    private let settings: Settings
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    init(tracker: AppTracker, settings: Settings) {
        self.settings = settings

        let view = StripView(tracker: tracker, settings: settings) { [weak self] app in self?.land(app) }
        panel.contentView = FirstClickHostingView(rootView: view)

        settings.$edge
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.place() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.place() }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.publisher(for: event)
                .sink { [weak self] _ in self?.tick() }
                .store(in: &cancellables)
        }
        // Polled for new windows, ones dragged under the strip, and the green button; AX only reports
        // those to an observer per app.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }

        place()
    }

    private func tick() {
        // Full-screen windows can't be resized, so the strip steps aside on their desktops.
        if Self.frontWindowIsFullScreen() {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        clearStrip()
    }

    private static func frontWindowIsFullScreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        guard let window: AXUIElement = AX.value(app, kAXFocusedWindowAttribute) else { return false }
        return AX.value(window, "AXFullScreen") == true
    }

    /// The strip's slice of the screen and the runway left over for the landed app.
    private func split() -> (strip: CGRect, runway: CGRect)? {
        guard let screen = NSScreen.screens.first else { return nil }
        let parts = screen.visibleFrame.divided(atDistance: settings.thickness, from: settings.edge.rectEdge)
        return (parts.slice, parts.remainder)
    }

    private func place() {
        guard let strip = split()?.strip else { return }
        panel.setFrame(strip, display: true)
        tick()
    }

    /// Keeps every window off the strip so nothing ends up underneath it.
    private func clearStrip() {
        // Mid-drag, the user is still placing the window.
        guard NSEvent.pressedMouseButtons == 0, let (strip, runway) = split() else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own }
            .map(\.processIdentifier)
        WindowMover.clear(WindowMover.axFrame(strip), into: WindowMover.axFrame(runway), pids: pids)
    }

    private func land(_ app: StripApp) {
        guard let runway = split()?.runway else { return }
        WindowMover.land(app, in: WindowMover.axFrame(runway))
    }
}
