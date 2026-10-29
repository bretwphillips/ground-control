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
    /// Finder windows minimized for the empty desktop, restored after.
    private var finderWindows: [AXUIElement] = []
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
        // Finder stays: something has to be the active app, and with everything hidden macOS
        // passes focus to the next app, un-hiding it. Its windows are minimized instead.
        hiddenByUs = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != own && $0.bundleIdentifier != Self.finder && !$0.isHidden
        }
        minimizeFinderWindows()

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
        guard panel != nil else { return }
        guard attempts > 0 else {
            probeMinimums()
            return
        }
        let gate = Set(latest?.leaves ?? [])
        let showing = hiddenByUs.filter { !$0.isHidden && !gate.contains($0.bundleIdentifier ?? "") }
        guard !showing.isEmpty else {
            probeMinimums()
            return
        }
        log.notice("editor: still showing \(showing.compactMap(\.bundleIdentifier).joined(separator: ", "), privacy: .public)")
        showing.forEach(hide)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.keepHidden(attempts: attempts - 1)
        }
    }

    private static let finder = "com.apple.finder"

    private func minimizeFinderWindows() {
        guard permissions.accessibility,
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: Self.finder).first else { return }
        let windows: [AXUIElement] = AX.value(AXUIElementCreateApplication(finder.processIdentifier), kAXWindowsAttribute) ?? []
        finderWindows = windows.filter {
            AX.value($0, kAXSubroleAttribute) == kAXStandardWindowSubrole && AX.value($0, kAXMinimizedAttribute) != true
        }
        for window in finderWindows {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
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
        hiddenByUs.forEach(show)
        hiddenByUs = []
        for window in finderWindows {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        finderWindows = []
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
        // A small gap between windows keeps the borders between them easy to grab.
        let gap = GateEditorModel.gap
        let frames = (layout?.frames(in: WindowMover.axFrame(runway)) ?? []).map { (id: $0.id, frame: $0.frame.insetBy(dx: gap, dy: gap)) }
        let ids = Set(frames.map(\.id))
        for id in placed.subtracting(ids) {
            running(id).map(hide)
        }
        for (id, frame) in frames {
            guard let app = running(id) else {
                openWindow(id)
                continue
            }
            let wasHidden = app.isHidden
            show(app)
            guard permissions.accessibility, let window = WindowMover.mainWindow(of: app.processIdentifier) else {
                if permissions.accessibility, let minimized = WindowMover.minimizedWindow(of: app.processIdentifier) {
                    AXUIElementSetAttributeValue(minimized, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    applyAgain(after: 0.6)
                } else if permissions.accessibility, !wasHidden, WindowMover.hasWindowElsewhere(app.processIdentifier) {
                    // Accessibility only sees windows on the desktop in view. A window it misses
                    // may also be minimized, which reopening restores; if that doesn't bring one,
                    // it's on another desktop.
                    if opened.contains(id) {
                        model?.elsewhere.insert(id)
                    } else {
                        openWindow(id)
                    }
                } else {
                    // Running with every window closed, like Calendar after ⌘W.
                    log.notice("editor: no window for \(id, privacy: .public)")
                    openWindow(id)
                }
                continue
            }
            // A full-screen window is a desktop of its own and won't take a zone until it leaves.
            if AX.value(window, "AXFullScreen") == true {
                AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
                log.notice("editor: \(id, privacy: .public) leaving full screen")
                // The animation's length varies, so it's placed more than once.
                applyAgain(after: 1)
                applyAgain(after: 2.5)
                continue
            }
            // Accessibility sees it, so it's on this desktop.
            model?.elsewhere.remove(id)
            let before = WindowMover.frame(of: window)
            if homes[id] == nil, let before {
                homes[id] = (window, before)
            }
            WindowMover.setFrame(window, frame)
            let landed = WindowMover.frame(of: window)
            log.notice("editor: \(id, privacy: .public) to \(String(describing: frame), privacy: .public), now \(String(describing: landed), privacy: .public), hidden: \(app.isHidden)")
            guard let landed, landed.size != frame.size else {
                model?.tooSmall[id] = nil
                continue
            }
            if landed.size == before?.size, landed.width <= frame.width + 1, landed.height <= frame.height + 1 {
                // It doesn't resize (Calculator) but fits, so it sits in the middle of its zone.
                model?.tooSmall[id] = nil
                WindowMover.setFrame(window, CGRect(
                    x: frame.midX - landed.width / 2,
                    y: frame.midY - landed.height / 2,
                    width: landed.width,
                    height: landed.height
                ))
            } else if landed.size == before?.size {
                // Didn't change size at all: it ignores resizing, which says nothing about how
                // small it can go, so nothing is learned.
                model?.tooSmall[id] = landed.size
            } else if landed.width > frame.width + 1 || landed.height > frame.height + 1 {
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

    private func applyAgain(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            apply(latest)
        }
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
        setHidden(app, true)
    }

    private func show(_ app: NSRunningApplication) {
        setHidden(app, false)
    }

    private func setHidden(_ app: NSRunningApplication, _ hidden: Bool) {
        if permissions.accessibility {
            let value = hidden ? kCFBooleanTrue : kCFBooleanFalse
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXHiddenAttribute as CFString, value!)
        } else if hidden {
            app.hide()
        } else {
            app.unhide()
        }
    }

    /// While the other apps are hidden, their windows can be shrunk and put back unseen, which
    /// tells each one's minimum size before it's ever dropped.
    private func probeMinimums() {
        guard permissions.accessibility, let model, panel != nil else { return }
        let gate = Set(latest?.leaves ?? [])
        for app in hiddenByUs where app.isHidden {
            guard let id = app.bundleIdentifier, !gate.contains(id), model.minimums[id] == nil,
                  let window = WindowMover.mainWindow(of: app.processIdentifier),
                  let home = WindowMover.frame(of: window) else { continue }
            WindowMover.setFrame(window, CGRect(origin: home.origin, size: CGSize(width: 1, height: 1)))
            let smallest = WindowMover.frame(of: window)?.size
            WindowMover.setFrame(window, home)
            // Unchanged means it ignores resizing, not that it can't get any smaller.
            guard let smallest, smallest != home.size else { continue }
            model.learn(id, width: smallest.width, height: smallest.height)
            log.notice("editor: \(id, privacy: .public) can shrink to \(String(describing: smallest), privacy: .public)")
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
    /// Why the last drop was turned away, shown for a few seconds.
    @Published var notice: String?
    /// Apps whose window is on another desktop, out of reach.
    @Published var elsewhere: Set<String> = []
    /// The smallest each app's window has allowed, learned as it refuses and kept between gates;
    /// borders stop there and new splits make room for it.
    private(set) var minimums: [String: CGSize]
    /// The runway's size, which the layout's ratios divide.
    private let canvas: CGSize

    /// Space between a window and its zone's edge while editing. None, so what's built is exactly
    /// what opens; the overlay above the windows already keeps their edges out of reach.
    static let gap: CGFloat = 0
    /// The app just dropped, which leaves again if its window turns out not to fit.
    private var lastDrop: (id: String, at: Date)?

    /// The smallest a part of the layout can be along `axis`, from what its windows have allowed.
    func minimum(of node: GateLayout, along axis: GateLayout.Axis) -> CGFloat {
        switch node {
        case .app(let id):
            let size = minimums[id] ?? .zero
            let needed = axis == .columns ? size.width : size.height
            return needed > 0 ? needed + GateEditorModel.gap * 2 : 0
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
        minimums = WindowMinimums.load()
            // Bigger than the whole runway was learned from an app that ignores resizing.
            .filter { $0.value.width < canvas.width && $0.value.height < canvas.height }
    }

    /// Dropping an app already in the gate moves it.
    func insert(_ id: String, beside target: String, at edge: GateLayout.Edge) {
        guard let candidate = inserting(id, beside: target, at: edge) else { return }
        guard fits(candidate, in: canvas) else {
            turnAway(id)
            return
        }
        layout = candidate
        lastDrop = (id, Date())
    }

    /// Whether dropping `id` there would leave every window enough room, as far as is known.
    func wouldFit(_ id: String, beside target: String, at edge: GateLayout.Edge) -> Bool {
        inserting(id, beside: target, at: edge).map { fits($0, in: canvas) } ?? true
    }

    private func inserting(_ id: String, beside target: String, at edge: GateLayout.Edge) -> GateLayout? {
        guard id != target, let layout else { return nil }
        let without = layout.removing(id) ?? .app(target)
        return fit(without.inserting(id, beside: target, at: edge), in: canvas)
    }

    /// A window refused to shrink past this; the layout makes room for it.
    func learn(_ id: String, width: CGFloat?, height: CGFloat?) {
        let known = minimums[id] ?? .zero
        let updated = CGSize(width: max(known.width, width ?? 0), height: max(known.height, height ?? 0))
        guard updated != known else { return }
        minimums[id] = updated
        WindowMinimums.save(minimums)
        guard let layout else { return }
        let fitted = fit(layout, in: canvas)
        if fits(fitted, in: canvas) {
            self.layout = fitted
        } else if let drop = lastDrop, drop.id == id, Date().timeIntervalSince(drop.at) < 3 {
            // Just dropped, and only found out once its window refused: it leaves the gate
            // instead of spilling over.
            self.layout = fit(layout.removing(id) ?? layout, in: canvas)
            tooSmall[id] = nil
            turnAway(id)
        } else {
            // Already in the gate: make what room there is rather than throw it out.
            self.layout = fitted
        }
    }

    private func turnAway(_ id: String) {
        let size = minimums[id].map { " (at least \(Int($0.width))×\(Int($0.height)))" } ?? ""
        let message = "\(AppIcon.name(id)) needs more room\(size). Make space for it, then drop it again."
        notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.notice == message { self?.notice = nil }
        }
    }

    /// Whether every window gets at least the room it needs.
    private func fits(_ node: GateLayout, in size: CGSize) -> Bool {
        switch node {
        case .app(let id):
            let needed = minimums[id] ?? .zero
            return needed.width + Self.gap * 2 <= size.width + 1 && needed.height + Self.gap * 2 <= size.height + 1
        case .split(let axis, let children, let ratios):
            return children.indices.allSatisfy { index in
                fits(children[index], in: axis == .columns
                    ? CGSize(width: ratios[index] * size.width, height: size.height)
                    : CGSize(width: size.width, height: ratios[index] * size.height))
            }
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
        tooSmall[id] = nil
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
            // Catches every click, so windows underneath can't be resized by accident.
            Color.black.opacity(0.001)
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
                Text("Drag apps from your airspace. Drop on an edge to split; drag borders to resize.")
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

            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.orange, in: Capsule())
                    .shadow(radius: 8)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.notice)
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
                Label("Drag apps here from your airspace", systemImage: "airplane.arrival")
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
    @State private var fits = true

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
                    } else if model.elsewhere.contains(id) {
                        Text("on another desktop: move it here in Mission Control")
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
                .onDrag {
                    DraggedApp.id = id
                    return NSItemProvider(object: id as NSString)
                }
                if let target {
                    highlight(target, in: proxy.size)
                }
            }
            .onDrop(of: [.plainText], delegate: EdgeDrop(
                size: proxy.size,
                target: $target,
                fits: $fits,
                wouldFit: { model.wouldFit($0, beside: id, at: $1) },
                onDrop: { model.insert($0, beside: id, at: $1) }
            ))
        }
        .padding(6)
    }

    /// The half the dropped app will take, red when it wouldn't have room there.
    private func highlight(_ edge: GateLayout.Edge, in size: CGSize) -> some View {
        let horizontal = edge.axis == .columns
        return RoundedRectangle(cornerRadius: 10)
            .fill((fits ? Color.accentColor : .red).opacity(0.3))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(fits ? .clear : .red, lineWidth: 2))
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
    @Binding var fits: Bool
    let wouldFit: (String, GateLayout.Edge) -> Bool
    let onDrop: (String, GateLayout.Edge) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let edge = edge(at: info.location)
        target = edge
        fits = DraggedApp.id.map { wouldFit($0, edge) } ?? true
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

/// The app being dragged. A drag's payload can only be read once it's dropped, so the tiles that
/// start one note it here for the hover warning.
enum DraggedApp {
    static var id: String?
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
