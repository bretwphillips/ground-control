import AppKit

/// Reads the badges the Dock shows on app icons, keyed by the Dock's label for each app.
/// Chat apps use "•" for plain unreads and a number for mentions and DMs.
enum DockBadges {
    static func read() -> [String: String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return [:]
        }
        var badges: [String: String] = [:]
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        for list in AX.children(root) where AX.value(list, kAXRoleAttribute) == kAXListRole {
            for item in AX.children(list) {
                guard let title: String = AX.value(item, kAXTitleAttribute),
                      let label: String = AX.value(item, "AXStatusLabel") else { continue }
                badges[title] = label
            }
        }
        return badges
    }
}
