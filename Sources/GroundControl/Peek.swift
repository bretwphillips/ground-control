import AppKit
import SwiftUI

/// What a tile under the pointer stands for.
enum Peek: Hashable {
    case app(String)
    case gate(UUID)
}

final class PeekModel: ObservableObject {
    @Published var peek: Peek?
}

/// A larger preview beside the strip for the tile under the pointer, like the Dock's magnification.
/// It ignores the pointer, so it never gets between the user and the strip.
final class PeekController {
    private let panel: NSPanel
    private let model = PeekModel()
    private let settings: Settings
    private var pending: DispatchWorkItem?

    init(tracker: AppTracker, previews: Previews, gates: GateStore, settings: Settings) {
        self.settings = settings
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PeekView(model: model, tracker: tracker, previews: previews, gates: gates))
    }

    var size: CGSize {
        let width: CGFloat = settings.size == .large ? 520 : 360
        return CGSize(width: width, height: width * 0.625 + PeekView.titleHeight)
    }

    /// `tile` is in screen coordinates. The first peek waits a moment so passing over the strip
    /// doesn't flash one; moving between tiles while one is showing switches straight away.
    func hover(_ peek: Peek?, tile: CGRect, strip: CGRect, edge: StripEdge) {
        pending?.cancel()
        guard let peek else {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.show(peek, tile: tile, strip: strip, edge: edge) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (panel.isVisible ? 0 : 0.35), execute: work)
    }

    func hide() {
        model.peek = nil
        panel.orderOut(nil)
    }

    private func show(_ peek: Peek, tile: CGRect, strip: CGRect, edge: StripEdge) {
        guard let screen = NSScreen.screens.first?.visibleFrame else { return }
        let size = size
        let gap: CGFloat = 8
        var origin: CGPoint = switch edge {
        case .top: CGPoint(x: tile.midX - size.width / 2, y: strip.minY - gap - size.height)
        case .bottom: CGPoint(x: tile.midX - size.width / 2, y: strip.maxY + gap)
        case .left: CGPoint(x: strip.maxX + gap, y: tile.midY - size.height / 2)
        case .right: CGPoint(x: strip.minX - gap - size.width, y: tile.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        model.peek = peek
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}

private struct PeekView: View {
    static let titleHeight: CGFloat = 30

    @ObservedObject var model: PeekModel
    @ObservedObject var tracker: AppTracker
    @ObservedObject var previews: Previews
    @ObservedObject var gates: GateStore

    var body: some View {
        let apps = Dictionary(tracker.allApps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: 0) {
            switch model.peek {
            case .app(let id):
                title(icon: AppIcon(bundleID: id, side: 18), name: apps[id]?.name ?? AppIcon.name(id), app: apps[id])
                Group {
                    if let pid = apps[id]?.pid, let image = previews.images[pid] {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        AppIcon(bundleID: id, side: 96)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
            case .gate(let id):
                if let gate = gates.gates.first(where: { $0.id == id }) {
                    title(icon: Image(systemName: "airplane.arrival"), name: gate.name, app: nil)
                    GateMap(gate: gate, apps: apps, previews: previews.images, iconSide: 40)
                        .padding(8)
                }
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.3), lineWidth: 0.5))
    }

    private func title(icon: some View, name: String, app: StripApp?) -> some View {
        HStack(spacing: 6) {
            icon
            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer()
            Badge(app: app, size: 11)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.titleHeight)
    }
}
