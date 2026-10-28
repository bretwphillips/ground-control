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
    /// Where each moved window started, so Cancel can put it back.
    private var homes: [String: (window: AXUIElement, frame: CGRect)] = [:]
    private var placed: Set<String> = []
    private var applyPending = false
    private var latest: GateLayout?

    init(permissions: Permissions, store: GateStore) {
        self.permissions = permissions
        self.store = store
    }

    func open(id: UUID, name: String, layout: GateLayout?, runway: CGRect, onSave: @escaping (Gate) -> Void) {
        finish()
        self.runway = runway
        store.editing = true

        // An empty desktop to build on: everything outside the gate steps aside.
        let own = Bundle.main.bundleIdentifier
        let keep = Set(layout?.leaves ?? [])
        hiddenByUs = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != own && !keep.contains($0.bundleIdentifier ?? "") && !$0.isHidden
        }
        hiddenByUs.forEach { $0.hide() }

        let model = GateEditorModel(name: name, layout: layout)
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
    }

    private func cancel() {
        for (window, frame) in homes.values {
            WindowMover.setFrame(window, frame)
        }
        finish()
    }

    private func finish() {
        cancellable = nil
        panel?.orderOut(nil)
        panel = nil
        hiddenByUs.forEach { $0.unhide() }
        hiddenByUs = []
        homes = [:]
        placed = []
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
            running(id)?.hide()
        }
        for (id, frame) in frames {
            guard let app = running(id) else {
                if !placed.contains(id) { launch(id) }
                continue
            }
            if app.isHidden { app.unhide() }
            guard permissions.accessibility, let window = WindowMover.mainWindow(of: app.processIdentifier) else { continue }
            if homes[id] == nil, let home = WindowMover.frame(of: window) {
                homes[id] = (window, home)
            }
            WindowMover.setFrame(window, frame)
        }
        placed = ids
    }

    /// A launching app has no window yet, so it's placed again once it has had time to open one.
    private func launch(_ id: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        for delay in [1.5, 3.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                apply(latest)
            }
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
    }

    override var canBecomeKey: Bool { true }
}

final class GateEditorModel: ObservableObject {
    @Published var name: String
    @Published var layout: GateLayout?

    init(name: String, layout: GateLayout?) {
        self.name = name
        self.layout = layout
    }

    /// Dropping an app already in the gate moves it.
    func insert(_ id: String, beside target: String, at edge: GateLayout.Edge) {
        guard id != target, let layout else { return }
        let without = layout.removing(id) ?? .app(target)
        self.layout = without.inserting(id, beside: target, at: edge)
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
                        .onHover { inside in
                            if inside {
                                (columns ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            DragGesture(coordinateSpace: .named("gate"))
                                .onChanged { value in
                                    resize(index, by: columns ? value.translation.width / size.width : value.translation.height / size.height)
                                }
                                .onEnded { _ in dragStart = nil }
                        )
                }
            }
        }
    }

    /// Moves the border before child `index`, trading space between the two apps beside it.
    private func resize(_ index: Int, by delta: Double) {
        let base = dragStart ?? ratios
        dragStart = base
        let pair = base[index - 1] + base[index]
        guard pair > 0.2 else { return }
        var updated = base
        updated[index - 1] = min(max(base[index - 1] + delta, 0.1), pair - 0.1)
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
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(live ? 0.04 : 0.2))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2))
                HStack(spacing: 8) {
                    AppIcon(bundleID: id, side: 24)
                    Text(AppIcon.name(id)).font(.system(size: 13, weight: .medium)).lineLimit(1)
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
