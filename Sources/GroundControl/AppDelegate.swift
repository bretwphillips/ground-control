import AppKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let tracker = AppTracker(settings: settings)
        let previews = Previews(tracker: tracker, settings: settings, permissions: permissions)
        let strip = StripController(
            tracker: tracker, previews: previews, settings: settings, permissions: permissions, gateStore: gateStore
        )
        hotKeys.onAction = { [weak self, weak strip] action in
            guard let gates = strip?.gates else { return }
            switch action {
            case .gate(let index):
                guard let all = self?.gateStore.gates, index < all.count else { return }
                gates.open(all[index])
            case .named(.back): gates.openPrevious()
            case .named(.gateLeft): gates.step(by: -1)
            case .named(.gateRight): gates.step(by: 1)
            case .named(.appNext): gates.stepApp(by: 1)
            case .named(.appPrevious): gates.stepApp(by: -1)
            case .named(.answer): self?.flyBy?.answer()
            }
        }
        let flyBy = FlyBy(
            settings: settings,
            permissions: permissions,
            runway: { [weak strip] in strip?.runway() },
            land: { [weak strip] app in strip?.bringUp(app) }
        )
        tracker.onCall = { [weak flyBy] app, preview in flyBy?.call(app, preview: preview) }
        self.tracker = tracker
        self.previews = previews
        self.strip = strip
        self.flyBy = flyBy
        settingsWindow = SettingsWindow(settings: settings, permissions: permissions, hotKeys: hotKeys)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "airplane", accessibilityDescription: "Ground Control")
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

        let flights = NSMenu()
        for app in tracker?.apps ?? [] {
            let item = NSMenuItem(title: app.name, action: #selector(previewFlyBy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.id
            flights.addItem(item)
        }
        let flyByItem = NSMenuItem(title: "Preview a Fly-by", action: nil, keyEquivalent: "")
        flyByItem.submenu = flights
        menu.addItem(flyByItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Ground Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func newGate() {
        strip?.gates.newGate()
    }

    @objc private func showSettings() {
        settingsWindow?.show()
    }

    /// Waits a few seconds so there's time to click back into another app first.
    @objc private func previewFlyBy(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if settings.flyByPreview, !permissions.screenRecording {
            Permission.screenRecording.request()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let app = self?.tracker?.apps.first(where: { $0.id == id }) else { return }
            self?.tracker?.call(app, preview: true)
        }
    }
}
