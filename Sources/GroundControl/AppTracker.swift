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
    /// Every running app, including ones hidden from the strip, for building gates.
    @Published private(set) var allApps: [StripApp] = []
    @Published private(set) var landed: String?
    /// Apps whose badge just gained a mention, for as long as their fly-by lasts.
    @Published private(set) var calling: Set<String> = []

    var onCall: ((Call) -> Void)?

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
        allApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, id != own else { return nil }
                let pid = app.processIdentifier
                return StripApp(id: id, name: app.localizedName ?? id, icon: app.icon ?? NSImage(), pid: pid, badge: badges[pid])
            }
        apps = allApps.filter { !settings.hiddenApps.contains($0.id) }
    }

    func call(_ call: Call) {
        let id = call.app.id
        calling.insert(id)
        onCall?(call)
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.flyBySeconds) { [weak self] in
            self?.calling.remove(id)
        }
    }

    /// A notification banner appeared. Whether it calls depends on what should trigger a fly-by:
    /// every notification does, otherwise only urgent ones (badges cover mentions and DMs).
    func banner(from running: NSRunningApplication, text: String) {
        guard settings.flyBy, let app = allApps.first(where: { $0.pid == running.processIdentifier }) else { return }
        let urgent = settings.isUrgent(text)
        guard urgent || settings.flyByTrigger == .everything else { return }
        call(Call(app: app, kind: .notification, note: text, urgent: urgent))
    }

    /// A terminal that was busy has gone quiet.
    func finished(pid: pid_t) {
        guard settings.flyBy, settings.terminalFinished,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
              let app = allApps.first(where: { $0.pid == pid }) else { return }
        call(Call(app: app, kind: .finished, note: "finished"))
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

        guard announce, settings.flyBy, settings.flyByTrigger != .urgent else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in apps where app.pid != front {
            if Badges.mentions(latest[app.pid]) > Badges.mentions(previous[app.pid]) {
                call(Call(app: app, kind: .mention))
            } else if settings.flyByTrigger == .everything, latest[app.pid] != nil, previous[app.pid] == nil {
                call(Call(app: app, kind: .badge))
            }
        }
    }
}
