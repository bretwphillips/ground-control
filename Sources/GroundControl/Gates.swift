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

extension GateLayout {
    /// The smallest this part can be along `axis`, from the windows' known minimums.
    func minimum(along axis: Axis, _ minimums: [String: CGSize]) -> CGFloat {
        switch self {
        case .app(let id):
            let size = minimums[id] ?? .zero
            return axis == .columns ? size.width : size.height
        case .split(let splitAxis, let children, _):
            let parts = children.map { $0.minimum(along: axis, minimums) }
            // Side by side the minimums add up; stacked across, the widest one decides.
            return splitAxis == axis ? parts.reduce(0, +) : parts.max() ?? 0
        }
    }

    /// Grows the part holding `id` by `factor` at every level down to it, taking the room from its
    /// siblings in proportion, but never squeezing them below their windows' minimums.
    func squished(toward id: String, by factor: Double, in size: CGSize, _ minimums: [String: CGSize]) -> GateLayout {
        guard case .split(let axis, var children, let ratios) = self,
              let index = children.firstIndex(where: { $0.leaves.contains(id) }) else { return self }
        let length = max(axis == .columns ? size.width : size.height, 1)
        var updated = ratios
        let others = 1 - ratios[index]
        if others > 0 {
            var grown = min(ratios[index] * factor, 0.9)
            for sibling in ratios.indices where sibling != index {
                updated[sibling] = ratios[sibling] * (1 - grown) / others
            }
            // Siblings that would go below their minimum keep it, and the growth gives way.
            for sibling in ratios.indices where sibling != index {
                let floor = min(ratios[sibling], children[sibling].minimum(along: axis, minimums) / length)
                if updated[sibling] < floor {
                    grown -= floor - updated[sibling]
                    updated[sibling] = floor
                }
            }
            updated[index] = max(grown, ratios[index])
            let total = updated.reduce(0, +)
            updated = updated.map { $0 / total }
        }
        let childSize = axis == .columns
            ? CGSize(width: updated[index] * size.width, height: size.height)
            : CGSize(width: size.width, height: updated[index] * size.height)
        children[index] = children[index].squished(toward: id, by: factor, in: childSize, minimums)
        return .split(axis, children, updated)
    }
}

extension GateLayout {
    /// Roughly undoes `squished`, so a seam dragged while an app is grown is saved as the gate's
    /// plain layout and doesn't compound the next time that app grows.
    func unsquished(toward id: String, by factor: Double) -> GateLayout {
        guard case .split(let axis, var children, var ratios) = self,
              let index = children.firstIndex(where: { $0.leaves.contains(id) }) else { return self }
        let shown = ratios[index]
        if shown < 1 {
            let base = shown / factor
            for sibling in ratios.indices where sibling != index {
                ratios[sibling] *= (1 - base) / (1 - shown)
            }
            ratios[index] = base
        }
        children[index] = children[index].unsquished(toward: id, by: factor)
        return .split(axis, children, ratios)
    }

    /// The borders between neighbours, each with the split it belongs to and that split's area.
    func seams(in rect: CGRect, path: [Int] = []) -> [Seam] {
        guard case .split(let axis, let children, let ratios) = self else { return [] }
        var seams: [Seam] = []
        var offset = 0.0
        for index in children.indices {
            let part = axis == .columns
                ? CGRect(x: rect.minX + offset * rect.width, y: rect.minY, width: ratios[index] * rect.width, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY + offset * rect.height, width: rect.width, height: ratios[index] * rect.height)
            if index > 0 {
                seams.append(Seam(path: path, index: index, axis: axis, area: rect, offset: offset))
            }
            seams += children[index].seams(in: part, path: path + [index])
            offset += ratios[index]
        }
        return seams
    }

    func node(at path: ArraySlice<Int>) -> GateLayout? {
        guard let index = path.first else { return self }
        guard case .split(_, let children, _) = self, children.indices.contains(index) else { return nil }
        return children[index].node(at: path.dropFirst())
    }
}

/// A border between two neighbours in a gate: between children `index - 1` and `index` of the
/// split at `path`, which fills `area` (AX coordinates) and has `offset` of its length before it.
struct Seam: Equatable {
    let path: [Int]
    let index: Int
    let axis: GateLayout.Axis
    let area: CGRect
    let offset: Double

    /// The handle: across the gap and 6pt into both windows' edges, so a drag there can't catch
    /// one window's edge and resize it alone.
    func handle(gap: CGFloat) -> CGRect {
        let width = gap + 12
        return axis == .columns
            ? CGRect(x: area.minX + offset * area.width - width / 2, y: area.minY, width: width, height: area.height)
            : CGRect(x: area.minX, y: area.minY + offset * area.height - width / 2, width: area.width, height: width)
    }
}

/// The smallest size each app's window has allowed, learned by the gate editor.
enum WindowMinimums {
    static let key = "windowMinimums"

    static func load() -> [String: CGSize] {
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        return saved.compactMapValues { $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil }
    }

    static func save(_ minimums: [String: CGSize]) {
        UserDefaults.standard.set(minimums.mapValues { [$0.width, $0.height] }, forKey: key)
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
    @Published var current: UUID? {
        didSet {
            if let oldValue, oldValue != current { previous = oldValue }
        }
    }
    /// The gate open before the current one, for flipping back and forth.
    private(set) var previous: UUID?
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

    /// Moves a gate to where another one is, shifting the rest along.
    func move(_ id: UUID, to target: UUID) {
        guard let from = gates.firstIndex(where: { $0.id == id }),
              let to = gates.firstIndex(where: { $0.id == target }), from != to else { return }
        gates.insert(gates.remove(at: from), at: to)
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

    private let settings: Settings
    let desktop = DesktopController()
    /// The open gate as it's laid out on screen right now, squish included.
    private(set) var shown: GateLayout?
    private var focus: String?
    private var seams: SeamHandles!
    private var dragBase: GateLayout?
    private let windowHints = WindowHints()
    private var dragPending = false

    init(store: GateStore, permissions: Permissions, settings: Settings, runway: @escaping () -> CGRect?) {
        self.store = store
        self.permissions = permissions
        self.settings = settings
        self.runway = runway
        editor = GateEditor(permissions: permissions, store: store)
        desktop.reopenGate = { [weak self] front in
            guard let self, let id = store.current, let gate = store.gates.first(where: { $0.id == id }) else { return false }
            // Switching to an app outside the gate is about that app, not the gate.
            if let front, !gate.layout.leaves.contains(front) { return false }
            for id in gate.layout.leaves {
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { continue }
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXHiddenAttribute as CFString, kCFBooleanFalse)
            }
            open(gate, focus: front)
            return true
        }
        seams = SeamHandles(
            drag: { [weak self] seam, point in self?.drag(seam, to: point) },
            end: { [weak self] in self?.endDrag() }
        )
    }

    private var gap: CGFloat { CGFloat(settings.gateGap) }

    /// The layout's area: the runway grown by half a gap, so after each window gives up half a gap
    /// on every side the outer ones still meet the runway's edges.
    private func layoutArea(_ runway: CGRect) -> CGRect {
        runway.insetBy(dx: -gap / 2, dy: -gap / 2)
    }

    /// Where each window goes: its share of the runway, with `gap` between neighbours (but not
    /// around the outside) so the tray behind shows through.
    private func windowFrames(_ layout: GateLayout, in runway: CGRect) -> [(id: String, frame: CGRect)] {
        layout.frames(in: layoutArea(runway)).map { (id: $0.id, frame: $0.frame.insetBy(dx: gap / 2, dy: gap / 2)) }
    }

    /// While a gate is open: the tray behind it, and, while one of its apps is in front, handles on
    /// its seams and guards on its outer edges, so windows are only resized together.
    func refreshSeams() {
        guard dragBase == nil else { return }
        guard permissions.accessibility, !store.editing, !desktop.showing, store.current != nil, let shown,
              let runway = runway().map(WindowMover.axFrame) else {
            seams.show([], gap: gap, locks: [], tray: nil)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Something else in front (Finder, for the desktop) gets the whole screen, tray included.
        guard let front, shown.leaves.contains(front) else {
            seams.show([], gap: gap, locks: [], tray: nil)
            return
        }
        let edge: CGFloat = 6
        let locks = [
            CGRect(x: runway.minX, y: runway.minY, width: edge, height: runway.height),
            CGRect(x: runway.maxX - edge, y: runway.minY, width: edge, height: runway.height),
            CGRect(x: runway.minX, y: runway.minY, width: runway.width, height: edge),
            CGRect(x: runway.minX, y: runway.maxY - edge, width: runway.width, height: edge),
        ]
        seams.show(shown.seams(in: layoutArea(runway)), gap: gap, locks: locks, tray: runway)
    }

    /// Moves a seam to the pointer, resizing the windows on both sides together.
    private func drag(_ seam: Seam, to point: CGPoint) {
        guard let shown, let runway = runway().map(WindowMover.axFrame),
              case .split(_, let children, let ratios)? = (dragBase ?? shown).node(at: seam.path[...]) else { return }
        if dragBase == nil { dragBase = shown }
        let length = seam.axis == .columns ? seam.area.width : seam.area.height
        let position = seam.axis == .columns ? point.x - seam.area.minX : point.y - seam.area.minY
        let before = ratios[..<(seam.index - 1)].reduce(0, +)
        let pair = ratios[seam.index - 1] + ratios[seam.index]
        let minimums = WindowMinimums.load()
        let floorA = max(0.05, children[seam.index - 1].minimum(along: seam.axis, minimums) / length)
        let floorB = max(0.05, children[seam.index].minimum(along: seam.axis, minimums) / length)
        guard pair >= floorA + floorB else { return }
        var updated = ratios
        updated[seam.index - 1] = min(max(position / length - before, floorA), pair - floorB)
        updated[seam.index] = pair - updated[seam.index - 1]
        self.shown = (dragBase ?? shown).settingRatios(updated, at: seam.path[...])
        seams.move(self.shown?.seams(in: layoutArea(runway)) ?? [], gap: gap)

        // Windows follow at most every 50ms; some apps redraw slowly.
        guard !dragPending else { return }
        dragPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let layout = self.shown else { return }
            dragPending = false
            for (id, frame) in windowFrames(layout, in: runway) {
                place(id, in: frame, attempts: 1)
            }
        }
    }

    /// Saves where the seam was left as the gate's layout.
    private func endDrag() {
        guard dragBase != nil, let shown, let id = store.current,
              var gate = store.gates.first(where: { $0.id == id }) else {
            dragBase = nil
            return
        }
        dragBase = nil
        gate.layout = settings.squish && focus != nil ? shown.unsquished(toward: focus!, by: 1 + settings.squishAmount) : shown
        store.save(gate)
        settled = [:]
        openedAt = Date().addingTimeInterval(-2.5)
        log.notice("gate: seam moved in \(gate.name, privacy: .public)")
    }

    /// The gate's layout with the focused app grown, when squish is on.
    private func layout(of gate: Gate, focus: String?, in runway: CGRect) -> GateLayout {
        guard settings.squish, let focus else { return gate.layout }
        return gate.layout.squished(toward: focus, by: 1 + settings.squishAmount, in: runway.size, WindowMinimums.load())
    }

    /// Called when the user switches apps. Inside the open gate, the newly focused app grows; with
    /// auto-open on, switching to an app that belongs to another gate opens that gate.
    func focusChanged() {
        // Opening a gate activates each of its apps in turn; those switches aren't the user's.
        guard permissions.accessibility, !store.editing, Date().timeIntervalSince(openedAt) > 0.6,
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        let current = store.gates.first { $0.id == store.current }
        if let current, current.layout.leaves.contains(front) {
            guard settings.squish, let runway = runway().map(WindowMover.axFrame) else { return }
            shown = layout(of: current, focus: front, in: runway)
            focus = front
            for (id, frame) in shown.map({ windowFrames($0, in: runway) }) ?? [] {
                place(id, in: frame, attempts: 1)
            }
            refreshSeams()
            // The new arrangement is where the windows belong now.
            settled = [:]
            openedAt = Date().addingTimeInterval(-2.5)
        } else if settings.autoOpen, let gate = gate(for: front) {
            open(gate, focus: front)
        }
    }

    /// While ⌃⌥ is held: the next and previous app's keys over their windows in the open gate.
    func showWindowHints(_ showing: Bool) {
        guard showing, permissions.accessibility, !store.editing, let shown,
              let runway = runway().map(WindowMover.axFrame) else {
            windowHints.show([])
            return
        }
        let frames = windowFrames(shown, in: runway)
        let leaves = frames.map(\.id)
        guard leaves.count > 1 else {
            windowHints.show([])
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let from = leaves.firstIndex { $0 == front } ?? -1
        let next = (from + 1) % leaves.count
        let previous = (from - 1 + leaves.count) % leaves.count
        var hints: [(frame: CGRect, text: String)] = []
        if let key = settings.hint(.appNext) { hints.append((frames[next].frame, key)) }
        if let key = settings.hint(.appPrevious), previous != next { hints.append((frames[previous].frame, key)) }
        windowHints.show(hints)
    }

    /// Opens the gate `step` places along the strip from the open one, wrapping around the ends.
    /// With none open it starts from the last one that was.
    func step(by step: Int) {
        let gates = store.gates
        guard !gates.isEmpty else { return }
        let from = gates.firstIndex { $0.id == (store.current ?? store.previous) }
        let index = from.map { (($0 + step) % gates.count + gates.count) % gates.count } ?? 0
        open(gates[index])
    }

    /// Brings forward the app `step` places along the open gate from the one in front, wrapping
    /// around; squish then grows it.
    func stepApp(by step: Int) {
        guard let id = store.current, let gate = store.gates.first(where: { $0.id == id }) else { return }
        let leaves = gate.layout.leaves
        guard !leaves.isEmpty else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let from = leaves.firstIndex { $0 == front } ?? -step
        let next = leaves[((from + step) % leaves.count + leaves.count) % leaves.count]
        NSRunningApplication.runningApplications(withBundleIdentifier: next).first?.activate()
        TypingFocus.shared.restore(next)
    }

    /// Flips back to the gate open before this one.
    func openPrevious() {
        guard let target = store.previous, let gate = store.gates.first(where: { $0.id == target }) else { return }
        open(gate)
    }

    /// `focus` is the app to end up in front; by default the app in front keeps focus if it's in
    /// the gate, otherwise the gate's first app gets it.
    func open(_ gate: Gate, focus wanted: String? = nil) {
        store.current = gate.id
        openedAt = Date()
        settled = [:]
        reopened = []
        guard let runway = runway().map(WindowMover.axFrame) else { return }
        let leaves = gate.layout.leaves
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let focus = leaves.first { $0 == wanted } ?? leaves.first { $0 == front } ?? leaves.first
        shown = layout(of: gate, focus: focus, in: runway)
        self.focus = focus
        let frames = shown.map { windowFrames($0, in: runway) } ?? []
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
        if let focus { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { TypingFocus.shared.restore(focus) } }
        // Seams show once the apps have come forward.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.3) { [weak self] in self?.refreshSeams() }
    }

    /// The gate an app belongs to: the open one if it's there, otherwise the first that has it.
    func gate(for id: String) -> Gate? {
        let gates = store.gates.filter { $0.layout.leaves.contains(id) }
        return gates.first { $0.id == store.current } ?? gates.first
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
        // Showing the desktop hides the gate's apps for a moment; that isn't them moving away.
        guard permissions.accessibility, dragBase == nil, !desktop.showing, let id = store.current, Date().timeIntervalSince(openedAt) > 3,
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
                shown = nil
                refreshSeams()
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
