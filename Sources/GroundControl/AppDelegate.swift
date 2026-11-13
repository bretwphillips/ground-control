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
    private var glance: Glance?
    /// A gate's shortcut held down: the gate, which way it lies, and the wait before glancing.
    private var held: (gate: Gate, direction: Int, timer: Timer)?

    /// The gate a shortcut goes to, and which way it lies, for the shortcuts that go to one.
    private func target(of action: HotKeys.Action, _ gates: GateController) -> (Gate, Int)? {
        let gate: Gate?
        switch action {
        case .gate(let index):
            let all = gateStore.active
            gate = index < all.count ? all[index] : nil
        case .named(.back): gate = gateStore.previous.flatMap { id in gateStore.gates.first { $0.id == id } }
        case .named(.gateLeft): return gates.neighbour(by: -1).map { ($0, -1) }
        case .named(.gateRight): return gates.neighbour(by: 1).map { ($0, 1) }
        default: return nil
        }
        return gate.map { ($0, gates.direction(to: $0)) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = TypingFocus.shared
        let tracker = AppTracker(settings: settings)
        let previews = Previews(tracker: tracker, settings: settings, permissions: permissions)
        let strip = StripController(
            tracker: tracker, previews: previews, settings: settings, permissions: permissions, gateStore: gateStore
        )
        let glance = Glance(gates: strip.gates, previews: previews)
        self.glance = glance
        hotKeys.onAction = { [weak self, weak strip] action in
            guard let self, let strip else { return }
            let gates: GateController = strip.gates
            // A gate's key switches when tapped and glances at the gate while held.
            if let (gate, direction) = target(of: action, gates) {
                guard held == nil else { return }
                let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { _ in
                    glance.begin(gate, direction: direction)
                    glance.move(to: 1, animated: true)
                }
                held = (gate, direction, timer)
                return
            }
            if case .named(.answer) = action {} else if case .named(.desktop) = action {} else { strip.flash() }
            switch action {
            case .gate, .named(.back), .named(.gateLeft), .named(.gateRight): break
            case .named(.appNext): gates.stepApp(by: 1)
            case .named(.appPrevious): gates.stepApp(by: -1)
            case .named(.answer): self.flyBy?.answer()
            case .named(.desktop): gates.desktop.toggle()
            }
        }
        hotKeys.onRelease = { [weak self, weak strip] _ in
            guard let self, let (gate, direction, timer) = held else { return }
            held = nil
            if timer.isValid {
                timer.invalidate()
                strip?.flash()
                strip?.gates.switchTo(gate, direction: direction)
            } else {
                glance.end(commit: false)
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
        // A swipe brings the next gate in under the fingers: past halfway it goes there, otherwise
        // it was only a look.
        swipes.onScrub = { [weak strip] scrub in
            switch scrub {
            case .began(let step):
                guard let gate = strip?.gates.neighbour(by: step) else { return }
                glance.begin(gate, direction: step)
            case .moved(let progress):
                glance.move(to: progress)
            case .ended(let commit):
                glance.end(commit: commit)
                if commit { strip?.flash() }
            }
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
