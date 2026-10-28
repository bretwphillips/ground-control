import AppKit
import Combine

struct StripApp: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage
    let pid: pid_t
    var badge: String?
}

/// The apps circling in the pattern: running, regular, not hidden.
final class AppTracker: ObservableObject {
    @Published private(set) var apps: [StripApp] = []
    @Published private(set) var landed: String?
    /// Without Accessibility access windows can't be moved and badges can't be read.
    @Published private(set) var trusted = AXIsProcessTrusted()

    private let settings: Settings
    private var badges: [String: String] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    init(settings: Settings) {
        self.settings = settings

        let center = NSWorkspace.shared.notificationCenter
        let events = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        for event in events {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        settings.$hiddenApps
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // The Dock posts nothing when a badge changes, so it is polled.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollBadges()
        }
        badges = DockBadges.read()
        refresh()
    }

    func refresh() {
        let own = Bundle.main.bundleIdentifier
        landed = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, id != own, !settings.hiddenApps.contains(id) else { return nil }
                let name = app.localizedName ?? id
                return StripApp(id: id, name: name, icon: app.icon ?? NSImage(), pid: app.processIdentifier, badge: badges[name])
            }
    }

    private func pollBadges() {
        let nowTrusted = AXIsProcessTrusted()
        if nowTrusted != trusted { trusted = nowTrusted }
        let latest = DockBadges.read()
        guard latest != badges else { return }
        badges = latest
        refresh()
    }
}
