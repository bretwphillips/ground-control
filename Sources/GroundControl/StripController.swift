import AppKit
import Combine
import SwiftUI

/// Floats over every space without ever taking focus from the landed app.
final class StripPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
    }

    override var canBecomeKey: Bool { false }
}

final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class StripController {
    private let panel = StripPanel()
    private let settings: Settings
    private var cancellables = Set<AnyCancellable>()

    init(tracker: AppTracker, settings: Settings) {
        self.settings = settings

        let view = StripView(tracker: tracker, settings: settings) { [weak self] app in self?.land(app) }
        panel.contentView = FirstClickHostingView(rootView: view)

        settings.$edge
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.place() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.place() }
            .store(in: &cancellables)

        place()
        panel.orderFrontRegardless()
    }

    /// The strip's slice of the screen and the runway left over for the landed app.
    private func split() -> (strip: CGRect, runway: CGRect)? {
        guard let screen = NSScreen.screens.first else { return nil }
        let parts = screen.visibleFrame.divided(atDistance: settings.thickness, from: settings.edge.rectEdge)
        return (parts.slice, parts.remainder)
    }

    private func place() {
        guard let strip = split()?.strip else { return }
        panel.setFrame(strip, display: true)
    }

    private func land(_ app: StripApp) {
        guard let runway = split()?.runway else { return }
        WindowMover.land(app, in: WindowMover.axFrame(runway))
    }
}
