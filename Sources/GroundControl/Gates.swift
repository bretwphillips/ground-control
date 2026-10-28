import AppKit

/// Columns and rows of apps, nested to make any tiling.
indirect enum GateLayout: Codable, Equatable {
    case app(String)
    /// Ratios add up to 1.
    case split(Axis, [GateLayout], [Double])

    enum Axis: String, Codable {
        case columns, rows
    }

    enum Edge {
        case left, right, top, bottom

        var axis: Axis { self == .left || self == .right ? .columns : .rows }
        var leading: Bool { self == .left || self == .top }
    }

    var leaves: [String] {
        switch self {
        case .app(let id): [id]
        case .split(_, let children, _): children.flatMap(\.leaves)
        }
    }

    /// Each app's frame within `rect`, which has a top-left origin like AX and SwiftUI.
    func frames(in rect: CGRect) -> [(id: String, frame: CGRect)] {
        switch self {
        case .app(let id):
            return [(id, rect)]
        case .split(let axis, let children, let ratios):
            var frames: [(id: String, frame: CGRect)] = []
            var offset = 0.0
            for (child, ratio) in zip(children, ratios) {
                let part = axis == .columns
                    ? CGRect(x: rect.minX + offset * rect.width, y: rect.minY, width: ratio * rect.width, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + offset * rect.height, width: rect.width, height: ratio * rect.height)
                frames += child.frames(in: part)
                offset += ratio
            }
            return frames
        }
    }

    func inserting(_ id: String, beside target: String, at edge: Edge) -> GateLayout {
        switch self {
        case .app(let leaf) where leaf == target:
            return .split(edge.axis, edge.leading ? [.app(id), self] : [self, .app(id)], [0.5, 0.5])
        case .app:
            return self
        case .split(let axis, var children, let ratios):
            // Joining a line of apps running the same way shares its space evenly.
            if axis == edge.axis, let index = children.firstIndex(of: .app(target)) {
                children.insert(.app(id), at: edge.leading ? index : index + 1)
                return .split(axis, children, Array(repeating: 1 / Double(children.count), count: children.count))
            }
            return .split(axis, children.map { $0.inserting(id, beside: target, at: edge) }, ratios)
        }
    }

    func removing(_ id: String) -> GateLayout? {
        switch self {
        case .app(let leaf):
            return leaf == id ? nil : self
        case .split(let axis, let children, let ratios):
            let kept = zip(children, ratios).compactMap { child, ratio in child.removing(id).map { ($0, ratio) } }
            if kept.count <= 1 { return kept.first?.0 }
            let total = kept.reduce(0) { $0 + $1.1 }
            return .split(axis, kept.map(\.0), kept.map { $0.1 / total })
        }
    }

    func settingRatios(_ ratios: [Double], at path: ArraySlice<Int>) -> GateLayout {
        guard case .split(let axis, var children, let current) = self else { return self }
        guard let index = path.first else { return .split(axis, children, ratios) }
        children[index] = children[index].settingRatios(ratios, at: path.dropFirst())
        return .split(axis, children, current)
    }
}

struct Gate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var layout: GateLayout
}

final class GateStore: ObservableObject {
    @Published private(set) var gates: [Gate] = []
    /// The gate opened last, until another opens.
    @Published var current: UUID?
    /// A gate is being built over the runway.
    @Published var editing = false

    private let key = "gates.v2"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Gate].self, from: data) {
            gates = saved
        }
    }

    func save(_ gate: Gate) {
        if let index = gates.firstIndex(where: { $0.id == gate.id }) {
            gates[index] = gate
        } else {
            gates.append(gate)
        }
        persist()
    }

    func delete(_ id: UUID) {
        gates.removeAll { $0.id == id }
        if current == id { current = nil }
        persist()
    }

    /// Bundle ids that belong to some gate.
    var bundleIDs: Set<String> {
        Set(gates.flatMap(\.layout.leaves))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(gates) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

final class GateController {
    let store: GateStore
    private let permissions: Permissions
    private let runway: () -> CGRect?
    private let editor: GateEditor
    private var openedAt = Date.distantPast
    /// Where the open gate's windows settled, to notice when one is moved away.
    private var settled: [String: CGRect] = [:]
    /// Apps asked to reopen while this gate opened, so each is only asked once.
    private var reopened: Set<String> = []

    init(store: GateStore, permissions: Permissions, runway: @escaping () -> CGRect?) {
        self.store = store
        self.permissions = permissions
        self.runway = runway
        editor = GateEditor(permissions: permissions, store: store)
    }

    func open(_ gate: Gate) {
        store.current = gate.id
        openedAt = Date()
        settled = [:]
        reopened = []
        guard let runway = runway().map(WindowMover.axFrame) else { return }
        let frames = gate.layout.frames(in: runway)

        // The app in front keeps focus if it's part of the gate; otherwise the first one gets it.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let focus = frames.first { $0.id == front }?.id ?? frames.first?.id
        var order = frames.filter { $0.id != focus }
        order += frames.filter { $0.id == focus }

        // Each activation brings that app's main window forward; the short gaps keep macOS from
        // reordering them.
        var delay = 0.0
        for (id, frame) in order {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    place(id, in: frame, attempts: 20)
                }
                continue
            }
            place(id, in: frame, attempts: 6)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { app.activate() }
            delay += 0.04
        }
        log.notice("gate: \(gate.name, privacy: .public)")
    }

    func newGate() {
        edit(id: UUID(), name: "Gate \(store.gates.count + 1)", layout: nil)
    }

    func edit(_ gate: Gate) {
        edit(id: gate.id, name: gate.name, layout: gate.layout)
    }

    private func edit(id: UUID, name: String, layout: GateLayout?) {
        guard let runway = runway() else { return }
        editor.open(id: id, name: name, layout: layout, runway: runway) { [weak self] saved in
            self?.store.save(saved)
            self?.open(saved)
        }
    }

    /// Puts the app's window in its spot: restored from the Dock or taken out of full screen first,
    /// and retried while a launching app has no window yet. A window on another desktop can't be
    /// reached and is left there.
    private func place(_ id: String, in frame: CGRect, attempts: Int) {
        guard permissions.accessibility, attempts > 0 else { return }
        let retry = { [weak self] (delay: Double) in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self?.place(id, in: frame, attempts: attempts - 1)
            }
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else {
            retry(0.5)
            return
        }
        let pid = app.processIdentifier
        guard let window = WindowMover.mainWindow(of: pid) else {
            if let minimized = WindowMover.minimizedWindow(of: pid) {
                log.notice("gate: restoring \(id, privacy: .public) from the Dock")
                AXUIElementSetAttributeValue(minimized, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                retry(0.5)
            } else if !app.isHidden, WindowMover.hasWindowElsewhere(pid) {
                let all: [AXUIElement] = AX.value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
                log.notice("gate: \(id, privacy: .public) has no window here (\(all.count) visible to Accessibility)")
                if !reopened.contains(id) {
                    // Accessibility can miss a minimized window; reopening the app, as a Dock click
                    // does, restores one. A window on another desktop stays out of reach.
                    reopened.insert(id)
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = false
                        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                    }
                    retry(0.8)
                }
            } else {
                retry(0.5)
            }
            return
        }
        if AX.value(window, "AXFullScreen") == true {
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
            retry(1.2)
            return
        }
        WindowMover.setFrame(window, frame)
    }

    /// Lets go of the open gate once one of its windows leaves where it settled: moved, resized,
    /// minimized, hidden, full screen or closed. Clicking the gate puts it all back.
    func checkDrift() {
        guard permissions.accessibility, let id = store.current, Date().timeIntervalSince(openedAt) > 3,
              let gate = store.gates.first(where: { $0.id == id }) else { return }
        if settled.isEmpty {
            // Windows still nowhere to be seen by now (another desktop) don't count.
            for appID in gate.layout.leaves {
                settled[appID] = currentFrame(of: appID)
            }
            return
        }
        for (appID, frame) in settled {
            guard let current = currentFrame(of: appID),
                  abs(current.minX - frame.minX) < 8, abs(current.minY - frame.minY) < 8,
                  abs(current.width - frame.width) < 8, abs(current.height - frame.height) < 8 else {
                log.notice("gate: let go, \(appID, privacy: .public) moved")
                store.current = nil
                settled = [:]
                return
            }
        }
    }

    private func currentFrame(of id: String) -> CGRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first, !app.isHidden,
              let window = WindowMover.mainWindow(of: app.processIdentifier),
              AX.value(window, "AXFullScreen") != true else { return nil }
        return WindowMover.frame(of: window)
    }
}
