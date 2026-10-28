import SwiftUI

struct StripView: View {
    @ObservedObject var tracker: AppTracker
    @ObservedObject var previews: Previews
    @ObservedObject var settings: Settings
    @ObservedObject var gates: GateStore
    let gateController: GateController
    @ObservedObject var patterns: Patterns
    @ObservedObject private var keys = KeyHints.shared
    let onLand: (StripApp) -> Void
    /// Where each tile sits in the strip's window, for finding the one under the pointer.
    let onTiles: ([Peek: CGRect]) -> Void

    var body: some View {
        let horizontal = settings.edge.isHorizontal
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
        let gated = gates.bundleIDs
        let apps = Dictionary(tracker.allApps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) {
            layout {
                ForEach(Array((gates.editing ? [] : gates.gates).enumerated()), id: \.element.id) { index, gate in
                    GateTile(
                        gate: gate,
                        apps: apps,
                        previews: previews.images,
                        size: settings.size,
                        current: gate.id == gates.current,
                        calling: gate.layout.leaves.contains { tracker.calling.contains($0) }
                    )
                    .onTapGesture { gateController.open(gate) }
                    .onDrag {
                        DraggedGate.id = gate.id
                        return NSItemProvider(object: "gate:\(gate.id.uuidString)" as NSString)
                    }
                    .onDrop(of: [.plainText], delegate: GateReorder(target: gate.id, store: gates))
                    .tileFrame(.gate(gate.id))
                    .contextMenu {
                        Button("Edit Gate…") { gateController.edit(gate) }
                        Divider()
                        Button("Delete Gate") { gates.delete(gate.id) }
                    }
                    .help(index < 9 ? "\(gate.name)  ⌃⌥\(index + 1)" : gate.name)
                    .overlay(alignment: .topLeading) {
                        if keys.showing, let text = gateKeys(index, gate) {
                            KeyCap(text: text).offset(x: -3, y: -3)
                        }
                    }
                }
                if !gates.editing, let pair = patterns.suggestion {
                    SuggestionTile(pair: pair, size: settings.size) {
                        if let gate = patterns.accept() {
                            gates.save(gate)
                            gateController.open(gate)
                        }
                    } dismiss: {
                        patterns.dismiss()
                    }
                }
                if !gates.editing {
                    SaveGateTile(size: settings.size)
                        .onTapGesture { gateController.newGate() }
                        .help("New gate")
                }
                if !gates.gates.isEmpty, !gates.editing {
                    Divider().frame(width: horizontal ? nil : 40, height: horizontal ? 24 : nil)
                }
                // While a gate is being built every app is offered, including ones in other gates.
                ForEach(gates.editing ? tracker.allApps : tracker.apps.filter { !gated.contains($0.id) }) { app in
                    Tile(
                        app: app,
                        size: settings.size,
                        preview: previews.images[app.pid],
                        landed: app.id == tracker.landed,
                        calling: tracker.calling.contains(app.id)
                    )
                    .onTapGesture { onLand(app) }
                    .tileFrame(.app(app.id))
                    .onDrag {
                        DraggedApp.id = app.id
                        DraggedGate.id = nil
                        return NSItemProvider(object: app.id as NSString)
                    }
                    .contextMenu {
                        Button("Hide from Strip") { settings.hiddenApps.insert(app.id) }
                    }
                    .help(app.name)
                }
                if !gates.editing {
                    DesktopTile(size: settings.size)
                        .overlay(alignment: .topLeading) {
                            if keys.showing, let text = settings.hint(.desktop) {
                                KeyCap(text: text).offset(x: -3, y: -3)
                            }
                        }
                        .onTapGesture { gateController.desktop.toggle() }
                        .help("Show the desktop (\(settings.shortcut(for: .desktop).display))")
                }
            }
            .padding(5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .onPreferenceChange(TileFrames.self, perform: onTiles)
    }

    /// The one key worth showing on this gate with ⌃⌥ held, so tiles don't fill with keys: the
    /// step key beside the open gate, else the back key on the last gate, else its number.
    private func gateKeys(_ index: Int, _ gate: Gate) -> String? {
        let all = gates.gates
        if let current = all.firstIndex(where: { $0.id == gates.current }), all.count > 1, index != current {
            if index == (current + 1) % all.count, let key = settings.hint(.gateRight) { return key }
            if index == (current - 1 + all.count) % all.count, let key = settings.hint(.gateLeft) { return key }
        }
        if gate.id == gates.previous, gate.id != gates.current, let key = settings.hint(.back) { return key }
        return index < 9 ? "\(index + 1)" : nil
    }
}

private struct GateTile: View {
    let gate: Gate
    let apps: [String: StripApp]
    let previews: [pid_t: NSImage]
    let size: StripSize
    let current: Bool
    let calling: Bool

    var body: some View {
        content
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(current ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.red, lineWidth: calling ? 2 : 0))
            .contentShape(Rectangle())
    }

    @ViewBuilder private var content: some View {
        switch size {
        case .icons:
            icons(20).frame(height: 24)
        case .names:
            HStack(spacing: 6) {
                icons(18)
                Text(gate.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .frame(height: 24)
        case .large:
            VStack(spacing: 4) {
                GateMap(gate: gate, apps: apps, previews: previews).frame(width: 150, height: 84)
                HStack(spacing: 4) {
                    Image(systemName: "airplane.arrival").font(.system(size: 10))
                    Text(gate.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(width: 150)
            }
        }
    }

    /// The gate's apps, overlapping like a stack of boarding passes.
    private func icons(_ side: CGFloat) -> some View {
        HStack(spacing: -side * 0.35) {
            ForEach(gate.layout.leaves.prefix(4), id: \.self) { id in
                AppIcon(bundleID: id, side: side)
                    .overlay(alignment: .topTrailing) { Badge(app: apps[id]).offset(x: 4, y: -4) }
            }
        }
    }
}

/// Where each of a gate's windows sits, with live previews where there are any.
struct GateMap: View {
    let gate: Gate
    let apps: [String: StripApp]
    let previews: [pid_t: NSImage]
    var iconSide: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.08))
                ForEach(gate.layout.frames(in: CGRect(origin: .zero, size: proxy.size)), id: \.id) { spot in
                    let frame = spot.frame.insetBy(dx: 1, dy: 1)
                    Group {
                        if let pid = apps[spot.id]?.pid, let image = previews[pid] {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.clear.overlay { AppIcon(bundleID: spot.id, side: min(iconSide, frame.height * 0.6)) }
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.5), lineWidth: 0.5))
                    .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
    }
}

/// "You keep switching between these two: make them a gate?"
private struct SuggestionTile: View {
    let pair: Patterns.Pair
    let size: StripSize
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                AppIcon(bundleID: pair.first, side: 18)
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 9, weight: .bold))
                AppIcon(bundleID: pair.second, side: 18)
            }
            if size != .icons {
                Text("Make a gate?").font(.system(size: 11, weight: .medium))
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Don't suggest these two again")
        }
        .padding(.horizontal, 7)
        .frame(height: size == .large ? 84 : 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3])))
        .contentShape(Rectangle())
        .onTapGesture(perform: accept)
        .help("You switch between these two a lot. Click to make them a gate, side by side.")
    }
}

/// The gate being dragged along the strip. A drag's payload can only be read once it's dropped,
/// so the tile that starts one notes it here and the others make room as it passes over them.
enum DraggedGate {
    static var id: UUID?
}

private struct GateReorder: DropDelegate {
    let target: UUID
    let store: GateStore

    func validateDrop(info: DropInfo) -> Bool {
        DraggedGate.id != nil
    }

    func dropEntered(info: DropInfo) {
        guard let id = DraggedGate.id, id != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { store.move(id, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        DraggedGate.id = nil
        return true
    }
}

private struct DesktopTile: View {
    let size: StripSize

    var body: some View {
        Image(systemName: "macwindow.on.rectangle")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: size == .large ? 40 : 24, height: size == .large ? 84 : 24)
            .contentShape(Rectangle())
    }
}

private struct SaveGateTile: View {
    let size: StripSize

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: size == .large ? 40 : 24, height: size == .large ? 84 : 24)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3])))
            .contentShape(Rectangle())
    }
}

struct AppIcon: View {
    let bundleID: String
    let side: CGFloat

    var body: some View {
        Image(nsImage: Self.icon(bundleID)).resizable().frame(width: side, height: side)
    }

    static func name(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }

    private static var cache: [String: NSImage] = [:]

    static func icon(_ bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        cache[bundleID] = icon
        return icon
    }
}

private struct Tile: View {
    let app: StripApp
    let size: StripSize
    let preview: NSImage?
    let landed: Bool
    let calling: Bool

    @State private var pulse = false

    var body: some View {
        content
            .padding(.horizontal, size == .icons ? 2 : 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(landed ? Color.accentColor.opacity(0.25) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.red, lineWidth: calling ? 2 : 0))
            .scaleEffect(pulse ? 1.08 : 1)
            .contentShape(Rectangle())
            .onChange(of: calling) { _, now in
                if now {
                    withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { pulse = true }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { pulse = false }
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch size {
        case .icons:
            icon(22).overlay(alignment: .topTrailing) { Badge(app: app).offset(x: 6, y: -4) }
        case .names:
            HStack(spacing: 5) {
                icon(20).overlay(alignment: .topTrailing) { Badge(app: app).offset(x: 6, y: -4) }
                Text(app.name).font(.system(size: 11)).lineLimit(1)
            }
            .frame(height: 24)
        case .large:
            VStack(spacing: 4) {
                Group {
                    if let preview {
                        Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        icon(44)
                    }
                }
                .frame(width: 150, height: 84)
                .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.08)))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                HStack(spacing: 4) {
                    icon(14)
                    Text(app.name).font(.system(size: 11)).lineLimit(1)
                    Spacer(minLength: 0)
                    Badge(app: app)
                }
                .frame(width: 150)
            }
        }
    }

    private func icon(_ side: CGFloat) -> some View {
        Image(nsImage: app.icon).resizable().frame(width: side, height: side)
    }
}

/// The app's badge, coloured by how much it wants attention and shaped by it too, so the levels
/// read without colour: urgent carries "!", mentions a number, the rest a dot (✓ when finished).
struct Badge: View {
    let app: StripApp?
    var size: CGFloat = 8

    var body: some View {
        if let app, let attention = app.attention {
            let number = app.badge.map(Badges.mentions) ?? 0
            switch attention {
            case .urgent:
                label(number > 0 ? "!\(app.badge ?? "")" : "!", attention.color)
            case .mention:
                label(app.badge ?? "", attention.color)
            case .finished:
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.75, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: size * 1.3, height: size * 1.3)
                    .background(Circle().fill(attention.color))
            case .unread:
                Circle().fill(attention.color).frame(width: size * 0.75, height: size * 0.75)
            }
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, size * 0.4)
            .background(Capsule().fill(color))
    }
}

/// Hover tracking only runs while Ground Control is the active app, which the strip never is, so
/// tiles report where they are and the pointer is matched against them instead.
struct TileFrames: PreferenceKey {
    static var defaultValue: [Peek: CGRect] = [:]

    static func reduce(value: inout [Peek: CGRect], nextValue: () -> [Peek: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func tileFrame(_ peek: Peek) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: TileFrames.self, value: [peek: proxy.frame(in: .global)])
        })
    }
}
