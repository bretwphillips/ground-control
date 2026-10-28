import AppKit

/// A saved arrangement of windows: the apps that were showing and where.
struct Gate: Codable, Identifiable, Equatable {
    struct Spot: Codable, Equatable {
        var bundleID: String
        /// The window's frame as fractions of the runway, so a gate survives strip changes.
        var x, y, width, height: Double

        init(bundleID: String, frame: CGRect, runway: CGRect) {
            let frame = frame.intersection(runway)
            self.bundleID = bundleID
            x = (frame.minX - runway.minX) / runway.width
            y = (frame.minY - runway.minY) / runway.height
            width = frame.width / runway.width
            height = frame.height / runway.height
        }

        func frame(in runway: CGRect) -> CGRect {
            CGRect(
                x: runway.minX + x * runway.width,
                y: runway.minY + y * runway.height,
                width: width * runway.width,
                height: height * runway.height
            )
        }
    }

    var id = UUID()
    var name: String
    /// Front to back.
    var spots: [Spot]
}

final class GateStore: ObservableObject {
    @Published private(set) var gates: [Gate] = []
    /// The gate opened last, until another opens.
    @Published var current: UUID?

    private let key = "gates"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Gate].self, from: data) {
            gates = saved
        }
    }

    func add(_ gate: Gate) {
        gates.append(gate)
        save()
    }

    func replace(_ gate: Gate) {
        guard let index = gates.firstIndex(where: { $0.id == gate.id }) else { return }
        gates[index] = gate
        save()
    }

    func delete(_ id: UUID) {
        gates.removeAll { $0.id == id }
        if current == id { current = nil }
        save()
    }

    /// Bundle ids that belong to some gate.
    var bundleIDs: Set<String> {
        Set(gates.flatMap { $0.spots.map(\.bundleID) })
    }

    private func save() {
        if let data = try? JSONEncoder().encode(gates) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

final class GateController {
    let store: GateStore
    private let permissions: Permissions
    private let runway: () -> CGRect?

    init(store: GateStore, permissions: Permissions, runway: @escaping () -> CGRect?) {
        self.store = store
        self.permissions = permissions
        self.runway = runway
    }

    func open(_ gate: Gate) {
        store.current = gate.id
        let runway = runway().map(WindowMover.axFrame)
        // Back to front, so the gate's front app ends up on top. Each activation brings that app's
        // main window forward; the short gaps keep macOS from reordering them.
        var delay = 0.0
        for spot in gate.spots.reversed() {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: spot.bundleID).first else {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: spot.bundleID) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
                continue
            }
            if permissions.accessibility, let runway, let window = WindowMover.mainWindow(of: app.processIdentifier) {
                WindowMover.setFrame(window, spot.frame(in: runway))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { app.activate() }
            delay += 0.04
        }
        log.notice("gate: \(gate.name, privacy: .public)")
    }

    func saveCurrent() {
        guard let spots = captureSpots(), !spots.isEmpty,
              let name = ask("Save as Gate", message: "Name this arrangement of windows.", value: "Gate \(store.gates.count + 1)") else {
            return
        }
        let gate = Gate(name: name, spots: spots)
        store.add(gate)
        store.current = gate.id
    }

    func updateToCurrent(_ gate: Gate) {
        guard let spots = captureSpots(), !spots.isEmpty else { return }
        var updated = gate
        updated.spots = spots
        store.replace(updated)
    }

    func rename(_ gate: Gate) {
        guard let name = ask("Rename Gate", message: "", value: gate.name) else { return }
        var updated = gate
        updated.name = name
        store.replace(updated)
    }

    /// The apps showing now, front to back, each with its frontmost window. Read from the window
    /// list, which needs no permission for positions.
    private func captureSpots() -> [Gate.Spot]? {
        guard let runway = runway().map(WindowMover.axFrame),
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let own = ProcessInfo.processInfo.processIdentifier
        var seen = Set<pid_t>()
        var above: [CGRect] = []
        var spots: [Gate.Spot] = []
        for window in info {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 100, frame.height > 100 else { continue }
            defer { above.append(frame) }
            // Windows mostly hidden behind others aren't part of what the user sees.
            guard !seen.contains(pid), Self.uncovered(frame, by: above) > 0.15,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let id = app.bundleIdentifier else { continue }
            seen.insert(pid)
            spots.append(Gate.Spot(bundleID: id, frame: frame, runway: runway))
        }
        return spots
    }

    private static func uncovered(_ frame: CGRect, by above: [CGRect]) -> Double {
        let steps = 12
        var open = 0
        for i in 0..<steps {
            for j in 0..<steps {
                let point = CGPoint(
                    x: frame.minX + (Double(i) + 0.5) * frame.width / Double(steps),
                    y: frame.minY + (Double(j) + 0.5) * frame.height / Double(steps)
                )
                if !above.contains(where: { $0.contains(point) }) { open += 1 }
            }
        }
        return Double(open) / Double(steps * steps)
    }

    private func ask(_ title: String, message: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let entered = field.stringValue.trimmingCharacters(in: .whitespaces)
        return entered.isEmpty ? value : entered
    }
}
