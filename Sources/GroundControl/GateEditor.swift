import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Edits a gate in place: other apps are hidden, a see-through overlay covers the runway, and
/// with Accessibility each app's real window follows its zone as the layout changes.
final class GateEditor {
    private let permissions: Permissions
    private let store: GateStore
    private var panel: OverlayPanel?
    private var cancellable: AnyCancellable?
    private var runway = CGRect.zero
    private var hiddenByUs: [NSRunningApplication] = []
    private var previousFront: NSRunningApplication?
    /// Where each moved window started, so Cancel can put it back.
    private var homes: [String: (window: AXUIElement, frame: CGRect)] = [:]
    private var placed: Set<String> = []
    /// Apps asked to open a window this session, so they're only asked once.
    private var opened: Set<String> = []
    private var applyPending = false
    private var latest: GateLayout?
    private var model: GateEditorModel?

    init(permissions: Permissions, store: GateStore) {
        self.permissions = permissions
        self.store = store
    }

    func open(id: UUID, name: String, layout: GateLayout?, runway: CGRect, onSave: @escaping (Gate) -> Void) {
        finish()
        self.runway = runway
        store.editing = true

        // An empty desktop to build on; the gate's own apps reappear as they're placed.
        let own = Bundle.main.bundleIdentifier
        previousFront = NSWorkspace.shared.frontmostApplication
        hiddenByUs = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != own && !$0.isHidden
        }

        let model = GateEditorModel(name: name, layout: layout, canvas: runway.size)
        self.model = model
        let panel = OverlayPanel(frame: runway)
        panel.contentView = FirstClickHostingView(rootView: GateOverlay(model: model, live: permissions.accessibility) { [weak self] save in
            if save, let layout = model.layout {
                self?.finish()
                onSave(Gate(id: id, name: model.name, layout: layout))
            } else {
                self?.cancel()
            }
        })
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)

        cancellable = model.$layout.sink { [weak self] layout in self?.scheduleApply(layout) }
        keepHidden(attempts: 20)
    }

    /// Hides everything outside the gate, again until it stays hidden: an app can still be
    /// finishing a switch when it's first asked.
    private func keepHidden(attempts: Int) {
        guard panel != nil, attempts > 0 else { return }
        let gate = Set(latest?.leaves ?? [])
        let showing = hiddenByUs.filter { !$0.isHidden && !gate.contains($0.bundleIdentifier ?? "") }
        guard !showing.isEmpty else { return }
        showing.forEach(hide)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.keepHidden(attempts: attempts - 1)
        }
    }

    private func cancel() {
        for (window, frame) in homes.values {
            WindowMover.setFrame(window, frame)
        }
        let front = previousFront
        finish()
        front?.activate()
    }

    private func finish() {
        cancellable = nil
        model = nil
        panel?.orderOut(nil)
        panel = nil
        hiddenByUs.forEach { $0.unhide() }
        hiddenByUs = []
        previousFront = nil
        homes = [:]
        placed = []
        opened = []
        store.editing = false
    }

    /// Dragging a border changes the layout many times a second; windows follow at most every 80ms.
    private func scheduleApply(_ layout: GateLayout?) {
        latest = layout
        guard !applyPending else { return }
        applyPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            applyPending = false
            apply(latest)
        }
    }

    private func apply(_ layout: GateLayout?) {
        guard panel != nil else { return }
        let frames = layout?.frames(in: WindowMover.axFrame(runway)) ?? []
        let ids = Set(frames.map(\.id))
        for id in placed.subtracting(ids) {
            running(id).map(hide)
        }
        for (id, frame) in frames {
            guard let app = running(id) else {
                openWindow(id)
                continue
            }
            app.unhide()
            guard permissions.accessibility, let window = WindowMover.mainWindow(of: app.processIdentifier) else {
                // Running with every window closed, like Calendar after ⌘W.
                openWindow(id)
                continue
            }
            if homes[id] == nil, let home = WindowMover.frame(of: window) {
                homes[id] = (window, home)
            }
            WindowMover.setFrame(window, frame)
            guard let landed = WindowMover.frame(of: window), landed.size != frame.size else {
                model?.tooSmall[id] = nil
                continue
            }
            if landed.width > frame.width + 1 || landed.height > frame.height + 1 {
                // Its minimum is bigger than the zone: it keeps the zone's corner, the zone says how
                // much room it needs, and borders won't squeeze it further.
                model?.tooSmall[id] = landed.size
                WindowMover.setFrame(window, CGRect(origin: frame.origin, size: landed.size))
                model?.learn(
                    id,
                    width: landed.width > frame.width + 1 ? landed.width : nil,
                    height: landed.height > frame.height + 1 ? landed.height : nil
                )
            } else {
                // It can't grow (Calculator), so it sits in the middle of its zone.
                model?.tooSmall[id] = nil
                WindowMover.setFrame(window, CGRect(
                    x: frame.midX - landed.width / 2,
                    y: frame.midY - landed.height / 2,
                    width: landed.width,
                    height: landed.height
                ))
            }
        }
        placed = ids
    }

    /// Opening an app that's already running asks it for a window, as clicking its Dock icon does.
    /// The window takes a moment to appear, so it's placed again a few times after.
    private func openWindow(_ id: String) {
        guard !opened.contains(id), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        opened.insert(id)
        log.notice("editor: asking \(id, privacy: .public) for a window")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for delay in [1.5, 3.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                apply(latest)
            }
        }
    }

    /// macOS ignores a background app asking to hide the active one, but Accessibility can hide any
    /// app without Ground Control having to take focus first.
    private func hide(_ app: NSRunningApplication) {
        if permissions.accessibility {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXHiddenAttribute as CFString, kCFBooleanTrue)
        } else {
            app.hide()
        }
    }

    private func running(_ id: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }
}

/// Sits over the runway above other apps' windows, and can take typing without activating the app.
final class OverlayPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
}

final class GateEditorModel: ObservableObject {
    @Published var name: String
    @Published var layout: GateLayout?
    /// Apps whose window can't shrink to their zone, with the size they need.
    @Published var tooSmall: [String: CGSize] = [:]
    /// The smallest each app's window has allowed, learned as it refuses and kept between gates;
    /// borders stop there and new splits make room for it.
    private(set) var minimums: [String: CGSize]
    /// The runway's size, which the layout's ratios divide.
    private let canvas: CGSize

    private static let minimumsKey = "windowMinimums"

    /// The smallest a part of the layout can be along `axis`, from what its windows have allowed.
    func minimum(of node: GateLayout, along axis: GateLayout.Axis) -> CGFloat {
        switch node {
        case .app(let id):
            let size = minimums[id] ?? .zero
            return axis == .columns ? size.width : size.height
        case .split(let splitAxis, let children, _):
            let parts = children.map { minimum(of: $0, along: axis) }
            // Side by side the minimums add up; stacked across, the widest one decides.
            return splitAxis == axis ? parts.reduce(0, +) : parts.max() ?? 0
        }
    }

    init(name: String, layout: GateLayout?, canvas: CGSize) {
        self.name = name
        self.layout = layout
        self.canvas = canvas
        let saved = UserDefaults.standard.dictionary(forKey: Self.minimumsKey) as? [String: [Double]] ?? [:]
        minimums = saved.compactMapValues { $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil }
    }

    /// Dropping an app already in the gate moves it.
    func insert(_ id: String, beside target: String, at edge: GateLayout.Edge) {
        guard id != target, let layout else { return }
        let without = layout.removing(id) ?? .app(target)
        self.layout = fit(without.inserting(id, beside: target, at: edge), in: canvas)
    }

    /// A window refused to shrink past this; the layout makes room for it.
    func learn(_ id: String, width: CGFloat?, height: CGFloat?) {
        let known = minimums[id] ?? .zero
        let updated = CGSize(width: max(known.width, width ?? 0), height: max(known.height, height ?? 0))
        guard updated != known else { return }
        minimums[id] = updated
        UserDefaults.standard.set(minimums.mapValues { [$0.width, $0.height] }, forKey: Self.minimumsKey)
        if let layout {
            self.layout = fit(layout, in: canvas)
        }
    }

    /// Grows any part below what its windows allow, taking the room from its siblings in proportion
    /// to what they can spare. A split whose minimums can't all fit is left as it is.
    private func fit(_ node: GateLayout, in size: CGSize) -> GateLayout {
        guard case .split(let axis, let children, var ratios) = node else { return node }
        let length = axis == .columns ? size.width : size.height
        let floors = children.map { minimum(of: $0, along: axis) / max(length, 1) }
        if floors.reduce(0, +) <= 1 {
            let deficit = zip(ratios, floors).reduce(0) { $0 + max($1.1 - $1.0, 0) }
            let spare = zip(ratios, floors).map { max($0 - $1, 0) }
            let totalSpare = spare.reduce(0, +)
            if deficit > 0, totalSpare > 0 {
                ratios = ratios.indices.map { index in
                    ratios[index] < floors[index] ? floors[index] : ratios[index] - deficit * spare[index] / totalSpare
                }
            }
        }
        let fitted = children.indices.map { index in
            fit(children[index], in: axis == .columns
                ? CGSize(width: ratios[index] * size.width, height: size.height)
                : CGSize(width: size.width, height: ratios[index] * size.height))
        }
        return .split(axis, fitted, ratios)
    }

    func remove(_ id: String) {
        layout = layout?.removing(id)
    }

    func setRatios(_ ratios: [Double], at path: [Int]) {
        layout = layout?.settingRatios(ratios, at: path[...])
    }
}

private struct GateOverlay: View {
    @ObservedObject var model: GateEditorModel
    /// Real windows follow the zones; without that the zones stand in for them.
    let live: Bool
    let done: (Bool) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if let layout = model.layout {
                    NodeView(node: layout, path: [], model: model, live: live)
                } else {
                    EmptyGate(model: model)
                }
            }
            .coordinateSpace(name: "gate")

            HStack(spacing: 10) {
                Image(systemName: "airplane.arrival").foregroundStyle(.secondary)
                TextField("Gate name", text: $model.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 150)
                Text("Drag apps from the strip. Drop on an edge to split; drag borders to resize.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Cancel") { done(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { done(true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.layout == nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8)
            .padding(.top, 16)
        }
    }
}

private struct EmptyGate: View {
    @ObservedObject var model: GateEditorModel
    @State private var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.accentColor.opacity(targeted ? 0.15 : 0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor.opacity(targeted ? 1 : 0.6), style: StrokeStyle(lineWidth: 3, dash: [10]))
            )
            .overlay {
                Label("Drag apps here from the strip", systemImage: "airplane.arrival")
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(8)
            .onDrop(of: [.plainText], isTargeted: $targeted) { providers in
                loadID(providers) { model.layout = .app($0) }
            }
    }
}

private struct NodeView: View {
    let node: GateLayout
    let path: [Int]
    @ObservedObject var model: GateEditorModel
    let live: Bool

    var body: some View {
        switch node {
        case .app(let id):
            LeafView(id: id, model: model, live: live)
        case .split(let axis, let children, let ratios):
            SplitView(axis: axis, children: children, ratios: ratios, path: path, model: model, live: live)
        }
    }
}

private struct SplitView: View {
    let axis: GateLayout.Axis
    let children: [GateLayout]
    let ratios: [Double]
    let path: [Int]
    @ObservedObject var model: GateEditorModel
    let live: Bool
    @State private var dragStart: [Double]?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let columns = axis == .columns
            ZStack(alignment: .topLeading) {
                ForEach(children.indices, id: \.self) { index in
                    let start = ratios[..<index].reduce(0, +)
                    NodeView(node: children[index], path: path + [index], model: model, live: live)
                        .frame(
                            width: columns ? ratios[index] * size.width : size.width,
                            height: columns ? size.height : ratios[index] * size.height
                        )
                        .offset(x: columns ? start * size.width : 0, y: columns ? 0 : start * size.height)
                }
                ForEach(1..<children.count, id: \.self) { index in
                    let boundary = ratios[..<index].reduce(0, +)
                    Color.clear
                        .frame(width: columns ? 14 : size.width, height: columns ? size.height : 14)
                        .overlay {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: columns ? 6 : 60, height: columns ? 60 : 6)
                                .shadow(radius: 3)
                        }
                        .contentShape(Rectangle())
                        .offset(x: columns ? boundary * size.width - 7 : 0, y: columns ? 0 : boundary * size.height - 7)
                        // Set on every move: the windows underneath keep resetting it.
                        .onContinuousHover { phase in
                            switch phase {
                            case .active: (columns ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                            case .ended: NSCursor.arrow.set()
                            }
                        }
                        .gesture(
                            DragGesture(coordinateSpace: .named("gate"))
                                .onChanged { value in
                                    let length = columns ? size.width : size.height
                                    resize(index, by: (columns ? value.translation.width : value.translation.height) / length, length: length)
                                }
                                .onEnded { _ in dragStart = nil }
                        )
                }
            }
        }
    }

    /// Moves the border before child `index`, trading space between the two apps beside it, and
    /// stops where either would go below what its windows allow.
    private func resize(_ index: Int, by delta: Double, length: CGFloat) {
        let base = dragStart ?? ratios
        dragStart = base
        let pair = base[index - 1] + base[index]
        let floor = 0.05
        let before = max(floor, model.minimum(of: children[index - 1], along: axis) / length)
        let after = max(floor, model.minimum(of: children[index], along: axis) / length)
        guard pair >= before + after else { return }
        var updated = base
        updated[index - 1] = min(max(base[index - 1] + delta, before), pair - after)
        updated[index] = pair - updated[index - 1]
        model.setRatios(updated, at: path)
    }
}

private struct LeafView: View {
    let id: String
    @ObservedObject var model: GateEditorModel
    let live: Bool
    @State private var target: GateLayout.Edge?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                let needs = model.tooSmall[id]
                RoundedRectangle(cornerRadius: 10)
                    .fill((needs == nil ? Color.accentColor : .orange).opacity(live ? 0.04 : 0.2))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((needs == nil ? Color.accentColor : .orange).opacity(0.8), lineWidth: 2))
                HStack(spacing: 8) {
                    AppIcon(bundleID: id, side: 24)
                    Text(AppIcon.name(id)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let needs {
                        Text("needs \(Int(needs.width))×\(Int(needs.height))")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    Button { model.remove(id) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from gate")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .onDrag { NSItemProvider(object: id as NSString) }
                if let target {
                    highlight(target, in: proxy.size)
                }
            }
            .onDrop(of: [.plainText], delegate: EdgeDrop(size: proxy.size, target: $target) { dropped, edge in
                model.insert(dropped, beside: id, at: edge)
            })
        }
        .padding(4)
    }

    /// The half the dropped app will take.
    private func highlight(_ edge: GateLayout.Edge, in size: CGSize) -> some View {
        let horizontal = edge.axis == .columns
        return RoundedRectangle(cornerRadius: 10)
            .fill(Color.accentColor.opacity(0.3))
            .frame(width: horizontal ? size.width / 2 : size.width, height: horizontal ? size.height : size.height / 2)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: edge == .left ? .leading : edge == .right ? .trailing : edge == .top ? .top : .bottom
            )
            .allowsHitTesting(false)
    }
}

private struct EdgeDrop: DropDelegate {
    let size: CGSize
    @Binding var target: GateLayout.Edge?
    let onDrop: (String, GateLayout.Edge) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        target = edge(at: info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        target = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let edge = edge(at: info.location)
        target = nil
        return loadID(info.itemProviders(for: [.plainText])) { onDrop($0, edge) }
    }

    /// The side nearest the pointer, measured relative to the zone's shape.
    private func edge(at point: CGPoint) -> GateLayout.Edge {
        let dx = point.x / max(size.width, 1) - 0.5
        let dy = point.y / max(size.height, 1) - 0.5
        if abs(dx) > abs(dy) {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .top : .bottom
    }
}

/// Reads the bundle id a dragged app tile carries.
private func loadID(_ providers: [NSItemProvider], then use: @escaping (String) -> Void) -> Bool {
    guard let provider = providers.first else { return false }
    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
        guard let id = object as? NSString else { return }
        DispatchQueue.main.async { use(id as String) }
    }
    return true
}
