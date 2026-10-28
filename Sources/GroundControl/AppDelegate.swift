import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private var tracker: AppTracker?
    private var strip: StripController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AX.requestTrust()

        let tracker = AppTracker(settings: settings)
        self.tracker = tracker
        strip = StripController(tracker: tracker, settings: settings)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "airplane", accessibilityDescription: "Ground Control")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let edges = NSMenu()
        for edge in StripEdge.allCases {
            let item = NSMenuItem(title: edge.title, action: #selector(pickEdge(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = edge.rawValue
            item.state = edge == settings.edge ? .on : .off
            edges.addItem(item)
        }
        let edgeItem = NSMenuItem(title: "Strip Edge", action: nil, keyEquivalent: "")
        edgeItem.submenu = edges
        menu.addItem(edgeItem)

        let apps = NSMenu()
        let own = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != own }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in running {
            guard let id = app.bundleIdentifier else { continue }
            let item = NSMenuItem(title: app.localizedName ?? id, action: #selector(toggleApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = settings.hiddenApps.contains(id) ? .off : .on
            apps.addItem(item)
        }
        let appsItem = NSMenuItem(title: "Apps in Strip", action: nil, keyEquivalent: "")
        appsItem.submenu = apps
        menu.addItem(appsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Ground Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func pickEdge(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let edge = StripEdge(rawValue: raw) else { return }
        settings.edge = edge
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if settings.hiddenApps.contains(id) {
            settings.hiddenApps.remove(id)
        } else {
            settings.hiddenApps.insert(id)
        }
    }
}
