import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let permissions = Permissions()
    private let gateStore = GateStore()
    private let hotKeys = HotKeys()
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
        hotKeys.onGate = { [weak self, weak strip] index in
            guard let gates = self?.gateStore.gates, index < gates.count else { return }
            strip?.gates.open(gates[index])
        }
        let flyBy = FlyBy(
            settings: settings,
            permissions: permissions,
            runway: { [weak strip] in strip?.runway() },
            land: { [weak strip] app in strip?.land(app) }
        )
        tracker.onCall = { [weak flyBy] app, preview in flyBy?.call(app, preview: preview) }
        self.tracker = tracker
        self.previews = previews
        self.strip = strip
        self.flyBy = flyBy
        settingsWindow = SettingsWindow(settings: settings, permissions: permissions)

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

        let saveGate = NSMenuItem(title: "Save Windows as Gate…", action: #selector(saveGate), keyEquivalent: "")
        saveGate.target = self
        menu.addItem(saveGate)

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

    @objc private func saveGate() {
        strip?.gates.saveCurrent()
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
