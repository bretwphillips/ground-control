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
    private var revealedForKeys = false
    private var flashUntil = Date.distantPast
    private var hoverSince: Date?
    /// The last click anywhere. Clicks under the hidden airspace are work in the app there.
    private var lastClick = Date.distantPast
    private var clickMonitor: Any?
    private var lastNear = Date.distantPast

    private(set) var gates: GateController!
    private var peeks: PeekController!
    private var patterns: Patterns!
    /// Tile frames in the strip window's coordinates, which run down from its top-left.
    private var tiles: [Peek: CGRect] = [:]
    private var hovered: Peek?

    init(tracker: AppTracker, previews: Previews, settings: Settings, permissions: Permissions, gateStore: GateStore) {
        self.tracker = tracker
        self.settings = settings
        self.permissions = permissions
        gates = GateController(store: gateStore, permissions: permissions, settings: settings) { [weak self] in self?.runway() }
        patterns = Patterns(settings: settings, store: gateStore)
        peeks = PeekController(tracker: tracker, previews: previews, gates: gateStore, settings: settings)

        let view = StripView(
            tracker: tracker,
            previews: previews,
            settings: settings,
            gates: gateStore,
            gateController: gates,
            patterns: patterns,
            onLand: { [weak self] app in self?.land(app) },
            onTiles: { [weak self] tiles in self?.tiles = tiles }
        )
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
        // The runway grows or shrinks with the strip, so the open gate re-fits it.
        settings.$autoHide
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let id = gateStore.current, let gate = gateStore.gates.first(where: { $0.id == id }) else { return }
                gates.open(gate)
            }
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
        workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if let id = app?.bundleIdentifier { self?.patterns.activated(id) }
                self?.gates.focusChanged()
                // The next and previous apps move with the one in front.
                if KeyHints.shared.showing { self?.gates.showWindowHints(true) }
            }
            .store(in: &cancellables)
        // Polled for new windows, ones dragged under the strip, and the green button; AX only reports
        // those to an observer per app.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.trackPointer()
            self?.trackHover()
            KeyHints.shared.poll()
        }
        KeyHints.shared.$showing
            .removeDuplicates()
            .sink { [weak self] showing in
                guard let self else { return }
                // Holding ⌃⌥ reveals the strip too, so its keys can be seen.
                revealedForKeys = showing
                tick()
                gates.showWindowHints(showing)
            }
            .store(in: &cancellables)

        // Mouse clicks elsewhere can be watched without a permission; only keys need one.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.lastClick = Date()
        }

        place()
    }

    /// With Accessibility, the strip keeps its slice of the screen clear. Without it, it can't move
    /// windows aside, so it hides until the pointer reaches its edge instead of covering them.
    private var reserves: Bool { settings.keepClear && permissions.accessibility && !settings.autoHide }

    /// Brings a hidden strip out for a moment, so a shortcut or swipe shows where it landed.
    func flash() {
        guard !reserves else { return }
        flashUntil = Date().addingTimeInterval(1.5)
        tick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.tick() }
    }

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
            shown = reserves || revealed || revealedForKeys || Date() < flashUntil || !tracker.calling.isEmpty || gates.store.editing
        }
        if shown != panel.isVisible {
            shown ? panel.orderFrontRegardless() : panel.orderOut(nil)
            if !shown { peeks.hide() }
        }
        if shown, reserves { clearStrip() }
        gates.checkDrift()
        gates.refreshSeams()
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

        // Auto-hidden, resting on where the strip lives brings it out too. The pause is long enough
        // to click a window's buttons or tabs underneath without it appearing.
        let resting = settings.autoHide && strip.contains(mouse)
        // Clicking there (closing tabs, say) is using the app underneath, so each click starts the
        // wait over, and it comes out only after a second without one.
        if NSEvent.pressedMouseButtons != 0 { lastClick = Date() }
        let clicking = Date().timeIntervalSince(lastClick) < 1
        hoverSince = resting && !clicking ? hoverSince ?? Date() : nil
        let hovered = hoverSince.map { Date().timeIntervalSince($0) > 0.6 } ?? false

        if atEdge || hovered || (revealed && zone.contains(mouse)) { lastNear = Date() }
        let shouldReveal = atEdge || hovered || (revealed && Date().timeIntervalSince(lastNear) < 0.4)
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

    /// Finds the tile under the pointer and peeks at it.
    private func trackHover() {
        let frame = panel.frame
        let mouse = NSEvent.mouseLocation
        var found: (Peek, CGRect)?
        if panel.isVisible, !gates.store.editing, frame.contains(mouse) {
            for (peek, tile) in tiles {
                let onScreen = CGRect(x: frame.minX + tile.minX, y: frame.maxY - tile.maxY, width: tile.width, height: tile.height)
                if onScreen.contains(mouse) {
                    found = (peek, onScreen)
                    break
                }
            }
        }
        guard found?.0 != hovered else { return }
        hovered = found?.0
        peeks.hover(found?.0, tile: found?.1 ?? .zero, strip: frame, edge: settings.edge)
    }

    /// Brings the app up in its gate if it has one, otherwise on its own.
    func bringUp(_ app: StripApp) {
        if let gate = gates.gate(for: app.id) {
            gates.open(gate, focus: app.id)
        } else {
            land(app)
        }
    }

    func land(_ app: StripApp) {
        // A single app takes over from whatever gate was open.
        gates.store.current = nil
        guard permissions.accessibility, let runway = runway() else {
            NSRunningApplication(processIdentifier: app.pid)?.activate()
            return
        }
        WindowMover.land(app, in: WindowMover.axFrame(runway))
    }
}
