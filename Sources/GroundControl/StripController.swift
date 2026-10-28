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
    private let tracker: AppTracker
    private let settings: Settings
    private let permissions: Permissions
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var pointerTimer: Timer?
    private var revealed = false
    private var lastNear = Date.distantPast

    private(set) var gates: GateController!

    init(tracker: AppTracker, previews: Previews, settings: Settings, permissions: Permissions, gateStore: GateStore) {
        self.tracker = tracker
        self.settings = settings
        self.permissions = permissions
        gates = GateController(store: gateStore, permissions: permissions) { [weak self] in self?.runway() }

        let view = StripView(tracker: tracker, previews: previews, settings: settings, gates: gateStore, gateController: gates) {
            [weak self] app in self?.land(app)
        }
        panel.contentView = FirstClickHostingView(rootView: view)

        for change in [settings.objectWillChange, permissions.objectWillChange] {
            change
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.place() }
                .store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.place() }
            .store(in: &cancellables)
        tracker.$calling
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.tick() }
            .store(in: &cancellables)
        gateStore.$editing
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.tick() }
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
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.trackPointer()
        }

        place()
    }

    /// With Accessibility, the strip keeps its slice of the screen clear. Without it, it can't move
    /// windows aside, so it hides until the pointer reaches its edge instead of covering them.
    private var reserves: Bool { settings.keepClear && permissions.accessibility }

    /// Where landed apps go.
    func runway() -> CGRect? {
        guard let screen = NSScreen.screens.first else { return nil }
        return reserves ? split()?.runway ?? screen.visibleFrame : screen.visibleFrame
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

    private func tick() {
        let shown: Bool
        if permissions.accessibility, WindowMover.frontWindow().map({ AX.value($0, "AXFullScreen") == true }) == true {
            // Full-screen windows can't be resized, so the strip steps aside on their desktops.
            shown = false
        } else {
            shown = reserves || revealed || !tracker.calling.isEmpty || gates.store.editing
        }
        if shown != panel.isVisible {
            shown ? panel.orderFrontRegardless() : panel.orderOut(nil)
        }
        if shown, reserves { clearStrip() }
    }

    /// Without a reserved slice, pushing the pointer to the screen's edge reveals the strip, and it
    /// hides again shortly after the pointer leaves it.
    private func trackPointer() {
        guard !reserves, let strip = split()?.strip, let screen = NSScreen.screens.first?.frame else {
            revealed = false
            return
        }
        let mouse = NSEvent.mouseLocation
        let atEdge = switch settings.edge {
        case .top: mouse.y >= screen.maxY - 2
        case .bottom: mouse.y <= screen.minY + 2
        case .left: mouse.x <= screen.minX + 2
        case .right: mouse.x >= screen.maxX - 2
        }
        // The strip plus the gap out to the screen's edge, the menu bar included.
        let zone = strip.union(screen.divided(atDistance: 1, from: settings.edge.rectEdge).slice).insetBy(dx: -2, dy: -2)

        if atEdge || (revealed && zone.contains(mouse)) { lastNear = Date() }
        let shouldReveal = atEdge || (revealed && Date().timeIntervalSince(lastNear) < 0.4)
        guard shouldReveal != revealed else { return }
        revealed = shouldReveal
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

    func land(_ app: StripApp) {
        guard permissions.accessibility, let runway = runway() else {
            NSRunningApplication(processIdentifier: app.pid)?.activate()
            return
        }
        WindowMover.land(app, in: WindowMover.axFrame(runway))
    }
}
