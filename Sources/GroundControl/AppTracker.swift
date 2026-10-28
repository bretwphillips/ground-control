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
    /// Apps whose badge just gained a mention, for as long as their fly-by lasts.
    @Published private(set) var calling: Set<String> = []

    /// A badge gained a mention; `true` when it's a preview from the menu.
    var onCall: ((StripApp, Bool) -> Void)?

    private let settings: Settings
    private var badges: [pid_t: String] = [:]
    private var primed = false
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

        refresh()
        // Apps post nothing when their badge changes, so it is polled.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollBadges()
        }
        pollBadges()
    }

    func refresh() {
        let own = Bundle.main.bundleIdentifier
        landed = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, id != own, !settings.hiddenApps.contains(id) else { return nil }
                let pid = app.processIdentifier
                return StripApp(id: id, name: app.localizedName ?? id, icon: app.icon ?? NSImage(), pid: pid, badge: badges[pid])
            }
    }

    func call(_ app: StripApp, preview: Bool = false) {
        calling.insert(app.id)
        onCall?(app, preview)
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.flyBySeconds) { [weak self] in
            self?.calling.remove(app.id)
        }
    }

    private func pollBadges() {
        let pids = apps.map(\.pid)
        DispatchQueue.global(qos: .utility).async {
            var latest: [pid_t: String] = [:]
            for pid in pids {
                latest[pid] = Badges.read(pid: pid)
            }
            DispatchQueue.main.async { [weak self] in self?.update(latest) }
        }
    }

    private func update(_ latest: [pid_t: String]) {
        let previous = badges
        // The first read is what was already waiting at launch, not news.
        let announce = primed
        primed = true
        guard latest != previous else { return }
        badges = latest
        refresh()

        guard announce, settings.flyBy else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in apps where app.pid != front && Badges.mentions(latest[app.pid]) > Badges.mentions(previous[app.pid]) {
            call(app)
        }
    }
}
