import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let permissions = Permissions()
    private let gateStore = GateStore()
    private lazy var hotKeys = HotKeys(settings: settings)
    private var tracker: AppTracker?
    private var previews: Previews?
    private var flyBy: FlyBy?
    private var strip: StripController?
    private var settingsWindow: SettingsWindow?
    private var statusItem: NSStatusItem?
    private let meeting = MeetingWatcher()
    private let banners = BannerWatcher()
    /// The gate that was open when a call started, to go back to after.
    private var beforeMeeting: UUID?
    private var swipeFingers: AnyCancellable?
    private let updates = Updates()
    private var groundStopIcon: AnyCancellable?
    private var walkthrough: Walkthrough?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = TypingFocus.shared
        let tracker = AppTracker(settings: settings)
        let previews = Previews(tracker: tracker, settings: settings, permissions: permissions)
        let strip = StripController(
            tracker: tracker, previews: previews, settings: settings, permissions: permissions, gateStore: gateStore
        )
        hotKeys.onAction = { [weak self, weak strip] action in
            guard let gates = strip?.gates else { return }
            if case .named(.answer) = action {} else if case .named(.desktop) = action {} else { strip?.flash() }
            switch action {
            case .gate(let index):
                guard let all = self?.gateStore.active, index < all.count else { return }
                gates.switchTo(all[index])
            case .named(.back): gates.openPrevious()
            case .named(.gateLeft): gates.step(by: -1)
            case .named(.gateRight): gates.step(by: 1)
            case .named(.appNext): gates.stepApp(by: 1)
            case .named(.appPrevious): gates.stepApp(by: -1)
            case .named(.answer): self?.flyBy?.answer()
            case .named(.desktop): gates.desktop.toggle()
            }
        }
        let flyBy = FlyBy(
            settings: settings,
            permissions: permissions,
            meeting: meeting,
            runway: { [weak strip] in strip?.runway() },
            land: { [weak strip] app in strip?.bringUp(app) }
        )
        tracker.onCall = { [weak flyBy] call in flyBy?.call(call) }
        banners.onBanner = { [weak tracker] app, text in tracker?.banner(from: app, text: text) }
        previews.onFinished = { [weak tracker] pid in tracker?.finished(pid: pid) }
        meeting.onChange = { [weak self] live in self?.meetingChanged(live) }
        let swipes = SwipeWatcher.shared
        swipes.onSwipe = { [weak strip] step in
            strip?.gates.step(by: step)
            strip?.flash()
        }
        swipeFingers = settings.$swipeFingers.sink { fingers in
            swipes.fingers = fingers
            if fingers > 0 { swipes.start() }
        }
        self.tracker = tracker
        self.previews = previews
        self.strip = strip
        self.flyBy = flyBy
        // Give windows a moment to be found before checking the last gate still matches them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak strip] in strip?.gates.resume() }
        walkthrough = Walkthrough(permissions: permissions) { [weak strip] in strip?.gates.newGate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.walkthrough?.showIfFirstRun() }
        settingsWindow = SettingsWindow(settings: settings, permissions: permissions, hotKeys: hotKeys, gates: gateStore, updates: updates)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = TowerIcon.image()
        // The tower carries a no-entry sign while a ground stop is on.
        groundStopIcon = GroundStop.shared.$until
            .receive(on: RunLoop.main)
            .sink { [weak item] _ in item?.button?.image = TowerIcon.image(stopped: GroundStop.shared.active) }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let newGate = NSMenuItem(title: "New Gate…", action: #selector(newGate), keyEquivalent: "")
        newGate.target = self
        menu.addItem(newGate)

        let stop = GroundStop.shared
        let stops = NSMenu()
        if stop.active {
            let end = NSMenuItem(title: "End Ground Stop", action: #selector(endGroundStop), keyEquivalent: "")
            end.target = self
            stops.addItem(end)
        } else {
            for (title, minutes) in [("For 30 Minutes", 30.0), ("For 1 Hour", 60.0), ("Until Turned Off", -1.0)] {
                let item = NSMenuItem(title: title, action: #selector(startGroundStop(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = minutes
                stops.addItem(item)
            }
        }
        let stopItem = NSMenuItem(title: stop.active ? "Ground Stop (\(stop.description))" : "Ground Stop", action: nil, keyEquivalent: "")
        stopItem.submenu = stops
        menu.addItem(stopItem)

        let desktop = NSMenuItem(title: "Show Desktop", action: #selector(showDesktop), keyEquivalent: "")
        desktop.target = self
        menu.addItem(desktop)

        let tour = NSMenuItem(title: "Welcome Tour…", action: #selector(showWalkthrough), keyEquivalent: "")
        tour.target = self
        menu.addItem(tour)

        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Ground Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func newGate() {
        strip?.gates.newGate()
    }

    /// A call opens the gate chosen for calls, and ending it goes back to the gate from before.
    private func meetingChanged(_ live: Bool) {
        guard settings.meetingMode, let gates = strip?.gates,
              let gate = gateStore.gates.first(where: { $0.id.uuidString == settings.meetingGate }) else { return }
        if live {
            beforeMeeting = gateStore.current
            gates.open(gate)
        } else if let before = beforeMeeting, let previous = gateStore.gates.first(where: { $0.id == before }) {
            beforeMeeting = nil
            gates.open(previous)
        }
    }

    @objc private func startGroundStop(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Double else { return }
        GroundStop.shared.start(for: minutes < 0 ? nil : minutes)
    }

    @objc private func endGroundStop() {
        GroundStop.shared.end()
    }

    @objc private func showDesktop() {
        strip?.gates.desktop.toggle()
    }

    @objc private func showSettings() {
        settingsWindow?.show()
    }

    @objc private func showWalkthrough() {
        walkthrough?.show()
    }

    @objc private func checkForUpdates() {
        updates.check(asked: true)
    }
}
