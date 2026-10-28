import AppKit
import SwiftUI

/// The open gate's frame: floating handles over its seams (dragging one moves the border between
/// the two apps beside it), guards on its outer edges, and the tray behind it. Handles and guards
/// overlap the windows' edges, so no window can be resized on its own while the gate is open.
final class SeamHandles {
    private var panels: [SeamPanel] = []
    private var locks: [NSPanel] = []
    private let tray = TrayPanel()
    private let drag: (Seam, CGPoint) -> Void
    private let end: () -> Void

    init(drag: @escaping (Seam, CGPoint) -> Void, end: @escaping () -> Void) {
        self.drag = drag
        self.end = end
    }

    /// Everything is in AX coordinates.
    func show(_ seams: [Seam], gap: CGFloat, locks frames: [CGRect], tray area: CGRect?) {
        move(seams, gap: gap)
        while locks.count > frames.count {
            locks.removeLast().orderOut(nil)
        }
        while locks.count < frames.count {
            locks.append(Self.lock())
        }
        for (lock, frame) in zip(locks, frames) {
            lock.setFrame(WindowMover.appKitFrame(frame), display: false)
            lock.orderFrontRegardless()
        }
        if let area, gap > 0 {
            tray.setFrame(WindowMover.appKitFrame(area), display: true)
            tray.orderFrontRegardless()
        } else {
            tray.orderOut(nil)
        }
    }

    /// Panels are reused so a drag in progress keeps its handle.
    func move(_ seams: [Seam], gap: CGFloat) {
        while panels.count > seams.count {
            panels.removeLast().orderOut(nil)
        }
        while panels.count < seams.count {
            panels.append(SeamPanel(drag: drag, end: end))
        }
        for (panel, seam) in zip(panels, seams) {
            panel.seam = seam
            panel.setFrame(WindowMover.appKitFrame(seam.handle(gap: gap)), display: true)
            panel.orderFrontRegardless()
        }
    }

    /// An invisible strip that takes the clicks meant for a window's outer edge.
    private static func lock() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = FirstClickHostingView(rootView: Color.black.opacity(0.001))
        return panel
    }
}

/// Sits behind every window, just above the desktop, in the strip's material, so the gate's apps
/// look held in a tray. It never takes clicks.
private final class TrayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        contentView = NSHostingView(rootView: Rectangle().fill(.regularMaterial))
    }

    override var canBecomeKey: Bool { false }
}

private final class SeamPanel: NSPanel {
    var seam: Seam? {
        didSet { model.columns = seam?.axis == .columns }
    }
    private let model = SeamModel()

    init(drag: @escaping (Seam, CGPoint) -> Void, end: @escaping () -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        contentView = FirstClickHostingView(rootView: SeamView(model: model, drag: { [weak self] in
            // The pointer, not the gesture's translation: the handle moves under it as it drags.
            guard let seam = self?.seam else { return }
            drag(seam, WindowMover.axPoint(NSEvent.mouseLocation))
        }, end: end))
    }

    override var canBecomeKey: Bool { false }
}

private final class SeamModel: ObservableObject {
    @Published var columns = true
}

private struct SeamView: View {
    @ObservedObject var model: SeamModel
    let drag: () -> Void
    let end: () -> Void
    @State private var dragging = false

    var body: some View {
        ZStack {
            // Catches clicks across the whole handle, not just the line.
            Color.black.opacity(0.001)
            Capsule()
                .fill(dragging ? Color.accentColor : Color.secondary.opacity(0.55))
                .frame(width: model.columns ? 4 : nil, height: model.columns ? nil : 4)
                .frame(maxWidth: model.columns ? 4 : 60, maxHeight: model.columns ? 60 : 4)
                .shadow(radius: 2)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    dragging = true
                    drag()
                }
                .onEnded { _ in
                    dragging = false
                    end()
                }
        )
    }
}
