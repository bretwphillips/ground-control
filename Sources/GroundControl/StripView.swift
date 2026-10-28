import SwiftUI

struct StripView: View {
    @ObservedObject var tracker: AppTracker
    @ObservedObject var previews: Previews
    @ObservedObject var settings: Settings
    @ObservedObject var gates: GateStore
    let gateController: GateController
    let onLand: (StripApp) -> Void

    var body: some View {
        let horizontal = settings.edge.isHorizontal
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
        let gated = gates.bundleIDs
        let apps = Dictionary(tracker.apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) {
            layout {
                ForEach(Array((gates.editing ? [] : gates.gates).enumerated()), id: \.element.id) { index, gate in
                    GateTile(
                        gate: gate,
                        apps: apps,
                        size: settings.size,
                        current: gate.id == gates.current,
                        calling: gate.layout.leaves.contains { tracker.calling.contains($0) }
                    )
                    .onTapGesture { gateController.open(gate) }
                    .contextMenu {
                        Button("Edit Gate…") { gateController.edit(gate) }
                        Divider()
                        Button("Delete Gate") { gates.delete(gate.id) }
                    }
                    .help(index < 9 ? "\(gate.name)  ⌃⌥\(index + 1)" : gate.name)
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
                    .onDrag { NSItemProvider(object: app.id as NSString) }
                    .contextMenu {
                        Button("Hide from Strip") { settings.hiddenApps.insert(app.id) }
                    }
                    .help(app.name)
                }
            }
            .padding(5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }
}

private struct GateTile: View {
    let gate: Gate
    let apps: [String: StripApp]
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
                layoutMap.frame(width: 150, height: 84)
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
                    .overlay(alignment: .topTrailing) { Badge(label: apps[id]?.badge).offset(x: 4, y: -4) }
            }
        }
    }

    /// Where each window sits.
    private var layoutMap: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.08))
                ForEach(gate.layout.frames(in: CGRect(origin: .zero, size: proxy.size)), id: \.id) { spot in
                    let frame = spot.frame.insetBy(dx: 1, dy: 1)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.background)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.5), lineWidth: 0.5))
                        .overlay { AppIcon(bundleID: spot.id, side: min(22, frame.height * 0.6)) }
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
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
            icon(22).overlay(alignment: .topTrailing) { Badge(label: app.badge).offset(x: 6, y: -4) }
        case .names:
            HStack(spacing: 5) {
                icon(20).overlay(alignment: .topTrailing) { Badge(label: app.badge).offset(x: 6, y: -4) }
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
                    Badge(label: app.badge)
                }
                .frame(width: 150)
            }
        }
    }

    private func icon(_ side: CGFloat) -> some View {
        Image(nsImage: app.icon).resizable().frame(width: side, height: side)
    }
}

private struct Badge: View {
    let label: String?

    var body: some View {
        if let label {
            if label == "•" {
                Circle().fill(.red).frame(width: 6, height: 6)
            } else {
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(.red))
            }
        }
    }
}
