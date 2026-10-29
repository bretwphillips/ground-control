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
    /// Waiting to fly: in order, with when each arrived, so a held one isn't kept forever.
    private var queue: [(call: Call, at: Date)] = []
    private let focus = FocusWatcher()
    private let meeting: MeetingWatcher
    private var lastFlight: [String: Date] = [:]
    /// The last app that called, preview or not, for answering it from the keyboard.
    private var lastCaller: (app: StripApp, at: Date)?
    private var timer: Timer?

    init(
        settings: Settings,
        permissions: Permissions,
        meeting: MeetingWatcher,
        runway: @escaping () -> CGRect?,
        land: @escaping (StripApp) -> Void
    ) {
        self.settings = settings
        self.meeting = meeting
        self.permissions = permissions
        self.runway = runway
        self.land = land
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func call(_ call: Call) {
        let app = call.app
        lastCaller = (app, Date())
        guard settings.flyByPreview, permissions.screenRecording else { return }
        // A banner arriving for the fly-by already showing adds its text to it.
        if flight?.app.id == app.id {
            if let note = call.note { flight?.panel.model.note = note }
            return
        }
        if let index = queue.firstIndex(where: { $0.call.app.id == app.id }) {
            if call.note != nil || call.urgent { queue[index].call = call }
            return
        }
        // One fly-by a minute per app, so a busy channel can't keep pulling attention away.
        let preview = call.kind == .preview
        if !preview, !call.urgent, let last = lastFlight[app.id], Date().timeIntervalSince(last) < 60 { return }
        queue.append((call, Date()))
    }

    /// Whether to keep a waiting fly-by back: during a call, or while the user is deep in one app,
    /// up to the longest wait set. Urgent ones and previews always go.
    private func holding(_ waiting: (call: Call, at: Date)) -> Bool {
        guard !waiting.call.urgent, waiting.call.kind != .preview else { return false }
        if GroundStop.shared.active { return true }
        if settings.meetingMode, meeting.inMeeting { return true }
        let waited = Date().timeIntervalSince(waiting.at)
        return settings.holdWhileFocused && waited < settings.holdMinutes * 60 && focus.isFocused
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
        } else if let index = queue.firstIndex(where: { !holding($0) }) {
            depart(queue.remove(at: index).call)
        }
    }

    private func depart(_ call: Call) {
        let app = call.app
        guard let runway = runway() else { return }
        let panel = FlyByPanel(app: app, note: call.note, urgent: call.urgent) { [weak self] in
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
    /// What it's about: the notification's text, or "finished".
    @Published var note: String?
    var urgent = false
}

final class FlyByPanel: NSPanel {
    static let titleHeight: CGFloat = 26

    let model = FlyByModel()

    init(app: StripApp, note: String?, urgent: Bool, onClick: @escaping () -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        model.note = note
        model.urgent = urgent
        contentView = FirstClickHostingView(rootView: FlyByView(app: app, model: model, onClick: onClick))
    }

    override var canBecomeKey: Bool { false }
}

private struct FlyByView: View {
    let app: StripApp
    @ObservedObject var model: FlyByModel
    @ObservedObject private var keys = KeyHints.shared
    let onClick: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                Text(app.name).font(.system(size: 12, weight: .semibold))
                if model.urgent {
                    Text("urgent").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).background(Capsule().fill(.red))
                }
                if let note = model.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else if let badge = app.badge {
                    Text(badge).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if keys.showing, let key = Settings.shared.hint(.answer) {
                    KeyCap(text: key)
                    Text("to open").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                } else {
                    Text("Click to open").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                }
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
