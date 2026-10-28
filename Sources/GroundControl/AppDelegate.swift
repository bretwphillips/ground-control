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

        let unhide = NSMenuItem(title: "Show Hidden Apps", action: #selector(showHiddenApps), keyEquivalent: "")
        unhide.target = self
        unhide.isEnabled = !settings.hiddenApps.isEmpty
        menu.addItem(unhide)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Ground Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func pickEdge(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let edge = StripEdge(rawValue: raw) else { return }
        settings.edge = edge
    }

    @objc private func showHiddenApps() {
        settings.hiddenApps = []
    }
}
