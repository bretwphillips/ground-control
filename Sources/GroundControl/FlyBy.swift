import AppKit

/// Slides a calling app's real window into a corner of the runway without taking focus, then puts
/// it back unless the user clicks it.
final class FlyBy {
    private struct Flight {
        let app: StripApp
        let window: AXUIElement
        let home: CGRect
        let frame: CGRect
        var until: Date
    }

    private let settings: Settings
    private let permissions: Permissions
    private let runway: () -> CGRect?
    private var flight: Flight?
    private var queue: [StripApp] = []
    private var lastFlight: [String: Date] = [:]
    private var timer: Timer?

    init(settings: Settings, permissions: Permissions, runway: @escaping () -> CGRect?) {
        self.settings = settings
        self.permissions = permissions
        self.runway = runway
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func call(_ app: StripApp, preview: Bool) {
        guard settings.flyByWindow, permissions.accessibility else { return }
        // One fly-by a minute per app, so a busy channel can't keep pulling focus away.
        if !preview, let last = lastFlight[app.id], Date().timeIntervalSince(last) < 60 { return }
        guard flight?.app.id != app.id, !queue.contains(where: { $0.id == app.id }) else { return }
        queue.append(app)
    }

    private func tick() {
        if let current = flight {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == current.app.pid {
                // Clicked: it has the user's attention now, so it lands.
                if let runway = runway() { WindowMover.setFrame(current.window, runway) }
                flight = nil
                log.notice("fly-by landed: \(current.app.name)")
            } else if Date() >= current.until {
                if pointerIsOver(current.frame) {
                    flight?.until = Date() + 1
                } else {
                    returnHome(current)
                }
            }
        } else if !queue.isEmpty, userIsIdle() {
            depart(queue.removeFirst())
        }
    }

    private func depart(_ app: StripApp) {
        guard let runway = runway(),
              let window = WindowMover.mainWindow(of: app.pid),
              let home = WindowMover.frame(of: window) else { return }
        // A sideways glance: the top of the far side of the runway.
        let width = min(max(runway.width * 0.4, 480), runway.width)
        let frame = CGRect(x: runway.maxX - width - 12, y: runway.minY + 12, width: width, height: runway.height * 0.6)
        WindowMover.setFrame(window, frame)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        flight = Flight(app: app, window: window, home: home, frame: frame, until: Date() + settings.flyBySeconds)
        lastFlight[app.id] = Date()
        log.notice("fly-by: \(app.name)")
    }

    private func returnHome(_ current: Flight) {
        WindowMover.setFrame(current.window, current.home)
        // Raising the focused app's window puts the visitor back behind it.
        if let front = WindowMover.frontWindow() {
            AXUIElementPerformAction(front, kAXRaiseAction as CFString)
        }
        flight = nil
        log.notice("fly-by returned: \(current.app.name)")
    }

    /// Waits for a pause in typing, so a fly-by never lands mid-sentence.
    private func userIsIdle() -> Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) > 1.5
    }

    private func pointerIsOver(_ frame: CGRect) -> Bool {
        frame.contains(WindowMover.axPoint(NSEvent.mouseLocation))
    }
}
