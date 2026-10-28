import AppKit
import SwiftUI

/// Floating handles over the seams of the open gate. Dragging one moves the border between the two
/// apps beside it; the handle overlaps both windows' edges so neither can be resized alone there.
final class SeamHandles {
    private var panels: [SeamPanel] = []
    private let drag: (Seam, CGPoint) -> Void
    private let end: () -> Void

    init(drag: @escaping (Seam, CGPoint) -> Void, end: @escaping () -> Void) {
        self.drag = drag
        self.end = end
    }

    /// `seams` are in AX coordinates. Panels are reused so a drag in progress keeps its handle.
    func show(_ seams: [Seam]) {
        while panels.count > seams.count {
            panels.removeLast().orderOut(nil)
        }
        while panels.count < seams.count {
            panels.append(SeamPanel(drag: drag, end: end))
        }
        for (panel, seam) in zip(panels, seams) {
            panel.seam = seam
            panel.setFrame(WindowMover.appKitFrame(seam.handle), display: true)
            panel.orderFrontRegardless()
        }
    }
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
