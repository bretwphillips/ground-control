import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class GateEditor {
    private var window: NSWindow?

    func open(id: UUID, name: String, layout: GateLayout?, aspect: CGFloat, onSave: @escaping (Gate) -> Void) {
        window?.close()
        let model = GateEditorModel(name: name, layout: layout)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let view = GateEditorView(model: model, aspect: aspect) { [weak window] save in
            if save, let layout = model.layout {
                onSave(Gate(id: id, name: model.name, layout: layout))
            }
            window?.close()
        }
        window.title = layout == nil ? "New Gate" : "Edit Gate"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: 680, height: 560))
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
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

private struct GateEditorView: View {
    @ObservedObject var model: GateEditorModel
    let aspect: CGFloat
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $model.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .medium))

            Text("Drag apps onto the gate. Drop on an edge of an app to split it; drag the borders to resize.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(runningApps(), id: \.processIdentifier) { app in
                        if let id = app.bundleIdentifier {
                            HStack(spacing: 5) {
                                Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 18, height: 18)
                                Text(app.localizedName ?? id).font(.system(size: 11)).lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(model.layout?.leaves.contains(id) == true ? 0.03 : 0.08)))
                            .opacity(model.layout?.leaves.contains(id) == true ? 0.5 : 1)
                            .onDrag { NSItemProvider(object: id as NSString) }
                        }
                    }
                }
            }

            Group {
                if let layout = model.layout {
                    NodeView(node: layout, path: [], model: model)
                } else {
                    EmptyGate(model: model)
                }
            }
            .frame(width: 640, height: 640 / aspect)
            .coordinateSpace(name: "gate")
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

            HStack {
                Spacer()
                Button("Cancel") { done(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { done(true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.layout == nil)
            }
        }
        .padding(16)
        .fixedSize()
    }

    private func runningApps() -> [NSRunningApplication] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != own }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

private struct EmptyGate: View {
    @ObservedObject var model: GateEditorModel
    @State private var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(targeted ? Color.accentColor : .secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6]))
            .overlay {
                Label("Drag apps here", systemImage: "airplane.arrival")
                    .foregroundStyle(.secondary)
            }
            .onDrop(of: [.plainText], isTargeted: $targeted) { providers in
                loadID(providers) { model.layout = .app($0) }
            }
    }
}

private struct NodeView: View {
    let node: GateLayout
    let path: [Int]
    @ObservedObject var model: GateEditorModel

    var body: some View {
        switch node {
        case .app(let id):
            LeafView(id: id, model: model)
        case .split(let axis, let children, let ratios):
            SplitView(axis: axis, children: children, ratios: ratios, path: path, model: model)
        }
    }
}

private struct SplitView: View {
    let axis: GateLayout.Axis
    let children: [GateLayout]
    let ratios: [Double]
    let path: [Int]
    @ObservedObject var model: GateEditorModel
    @State private var dragStart: [Double]?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let columns = axis == .columns
            ZStack(alignment: .topLeading) {
                ForEach(children.indices, id: \.self) { index in
                    let start = ratios[..<index].reduce(0, +)
                    NodeView(node: children[index], path: path + [index], model: model)
                        .frame(
                            width: columns ? ratios[index] * size.width : size.width,
                            height: columns ? size.height : ratios[index] * size.height
                        )
                        .offset(x: columns ? start * size.width : 0, y: columns ? 0 : start * size.height)
                }
                ForEach(1..<children.count, id: \.self) { index in
                    let boundary = ratios[..<index].reduce(0, +)
                    Color.clear
                        .frame(width: columns ? 10 : size.width, height: columns ? size.height : 10)
                        .overlay {
                            Capsule()
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(width: columns ? 4 : 36, height: columns ? 36 : 4)
                        }
                        .contentShape(Rectangle())
                        .offset(x: columns ? boundary * size.width - 5 : 0, y: columns ? 0 : boundary * size.height - 5)
                        .onHover { inside in
                            if inside {
                                (columns ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            DragGesture(coordinateSpace: .named("gate"))
                                .onChanged { value in resize(index, by: columns ? value.translation.width / size.width : value.translation.height / size.height) }
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
    @State private var target: GateLayout.Edge?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.background)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4)))
                VStack(spacing: 6) {
                    AppIcon(bundleID: id, side: min(44, proxy.size.height * 0.4))
                    Text(AppIcon.name(id)).font(.system(size: 12)).lineLimit(1)
                }
                if let target {
                    highlight(target, in: proxy.size)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button { model.remove(id) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Remove from gate")
            }
            .onDrag { NSItemProvider(object: id as NSString) }
            .onDrop(of: [.plainText], delegate: EdgeDrop(size: proxy.size, target: $target) { dropped, edge in
                model.insert(dropped, beside: id, at: edge)
            })
        }
        .padding(4)
    }

    /// The half the dropped app will take.
    private func highlight(_ edge: GateLayout.Edge, in size: CGSize) -> some View {
        let horizontal = edge.axis == .columns
        return RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(0.25))
            .frame(width: horizontal ? size.width / 2 : size.width, height: horizontal ? size.height : size.height / 2)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: edge == .left ? .leading : edge == .right ? .trailing : edge == .top ? .top : .bottom
            )
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

    /// The side nearest the pointer, measured relative to the tile's shape.
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
