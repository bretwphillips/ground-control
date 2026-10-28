import AppKit
import ScreenCaptureKit
import SwiftUI

/// Shows a calling app's window as a live preview in a corner of the runway. macOS won't put another
/// app's window in front without giving it focus, so the preview is our own panel; clicking it lands
/// the app, and ignoring it lets it go.
final class FlyBy {
    private struct Flight {
        let id = UUID()
        let app: StripApp
        let panel: FlyByPanel
        var until: Date
        var capture: Task<Void, Never>?
    }

    private let settings: Settings
    private let permissions: Permissions
    private let runway: () -> CGRect?
    private let land: (StripApp) -> Void
    private var flight: Flight?
    private var queue: [StripApp] = []
    private var lastFlight: [String: Date] = [:]
    /// The last app that called, preview or not, for answering it from the keyboard.
    private var lastCaller: (app: StripApp, at: Date)?
    private var timer: Timer?

    init(settings: Settings, permissions: Permissions, runway: @escaping () -> CGRect?, land: @escaping (StripApp) -> Void) {
        self.settings = settings
        self.permissions = permissions
        self.runway = runway
        self.land = land
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func call(_ app: StripApp, preview: Bool) {
        lastCaller = (app, Date())
        guard settings.flyByPreview, permissions.screenRecording else { return }
        // One fly-by a minute per app, so a busy channel can't keep pulling attention away.
        if !preview, let last = lastFlight[app.id], Date().timeIntervalSince(last) < 60 { return }
        guard flight?.app.id != app.id, !queue.contains(where: { $0.id == app.id }) else { return }
        queue.append(app)
    }

    /// Answers the fly-by from the keyboard, as clicking it would; once it's gone, the last app to
    /// call within the past minute.
    func answer() {
        if let current = flight {
            land(current.app)
            end()
        } else if let caller = lastCaller, Date().timeIntervalSince(caller.at) < 60 {
            land(caller.app)
        }
        lastCaller = nil
    }

    private func tick() {
        if let current = flight {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == current.app.pid {
                end()
            } else if Date() >= current.until {
                if current.panel.frame.contains(NSEvent.mouseLocation) {
                    flight?.until = Date() + 1
                } else {
                    end()
                }
            }
        } else if !queue.isEmpty {
            depart(queue.removeFirst())
        }
    }

    private func depart(_ app: StripApp) {
        guard let runway = runway() else { return }
        let panel = FlyByPanel(app: app) { [weak self] in
            self?.land(app)
            self?.end()
        }
        var current = Flight(app: app, panel: panel, until: Date() + settings.flyBySeconds)
        let id = current.id
        current.capture = Task { @MainActor [weak self] in
            guard let window = await AppWindows.main(of: app.pid) else {
                self?.end()
                return
            }
            let size = Self.fit(window.frame.size, in: runway)
            panel.setFrame(
                CGRect(x: runway.maxX - size.width - 12, y: runway.maxY - size.height - 12, width: size.width, height: size.height),
                display: false
            )
            panel.orderFrontRegardless()

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(size.width * 2)
            config.height = Int((size.height - FlyByPanel.titleHeight) * 2)
            config.showsCursor = false
            while !Task.isCancelled, self?.flight?.id == id {
                do {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    panel.model.image = NSImage(cgImage: image, size: .zero)
                } catch {
                    log.error("capture failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        flight = current
        lastFlight[app.id] = Date()
        log.notice("fly-by: \(app.name)")
    }

    private func end() {
        guard let current = flight else { return }
        current.capture?.cancel()
        current.panel.orderOut(nil)
        flight = nil
        log.notice("fly-by ended: \(current.app.name)")
    }

    /// A sideways glance: about 40% of the runway's width, shaped like the window.
    private static func fit(_ window: CGSize, in runway: CGRect) -> CGSize {
        let aspect = window.height / max(window.width, 1)
        var width = min(max(runway.width * 0.4, 480), runway.width - 24)
        var height = width * aspect
        if height > runway.height * 0.7 {
            height = runway.height * 0.7
            width = height / aspect
        }
        return CGSize(width: width, height: height + FlyByPanel.titleHeight)
    }
}

final class FlyByModel: ObservableObject {
    @Published var image: NSImage?
}

final class FlyByPanel: NSPanel {
    static let titleHeight: CGFloat = 26

    let model = FlyByModel()

    init(app: StripApp, onClick: @escaping () -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        contentView = FirstClickHostingView(rootView: FlyByView(app: app, model: model, onClick: onClick))
    }

    override var canBecomeKey: Bool { false }
}

private struct FlyByView: View {
    let app: StripApp
    @ObservedObject var model: FlyByModel
    let onClick: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                Text(app.name).font(.system(size: 12, weight: .semibold))
                if let badge = app.badge {
                    Text(badge).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Click to open").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: FlyByPanel.titleHeight)
            Group {
                if let image = model.image {
                    Image(nsImage: image).resizable()
                } else {
                    Color.black.opacity(0.1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.red.opacity(0.6), lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
    }
}
