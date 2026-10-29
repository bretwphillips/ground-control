import AppKit

/// Updates follow tagged releases only, as in T Novel and Previously: what's merged but not
/// released reaches no one. Once a day (and from the menu) this asks GitHub for the latest release
/// and offers it if it's newer. Updating moves the clone the app was built from to that release,
/// rebuilds and relaunches; a clone that's mid-change is left alone and the release page opens.
final class Updates {
    static let repo = "bretwphillips/ground-control"

    struct Release {
        let tag: String
        let version: String
        let url: URL?
        let notes: String
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var automatic: Bool {
        get { defaults.object(forKey: "updates.automatic") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "updates.automatic") }
    }

    init() {
        // A check a day, give or take: looked at hourly, acted on once a day has passed.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        let last = defaults.double(forKey: "updates.checkedAt")
        guard automatic, Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        check(asked: false)
    }

    /// `asked` is from the menu: it always answers, even "up to date", and offers a release that
    /// was put off before.
    func check(asked: Bool) {
        Task { @MainActor in
            let release = await Self.latest()
            defaults.set(Date().timeIntervalSince1970, forKey: "updates.checkedAt")
            guard let release, Self.isNewer(release.version, than: current) else {
                if asked { tell("Ground Control is up to date", "You have \(current), the latest release.") }
                return
            }
            guard asked || defaults.string(forKey: "updates.skipped") != release.tag else { return }
            offer(release)
        }
    }

    private func offer(_ release: Release) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Ground Control \(release.version) is out"
        alert.informativeText = "You have \(current).\n\n" + String(release.notes.prefix(600))
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "View Release")
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertSecondButtonReturn: defaults.set(release.tag, forKey: "updates.skipped")
        default: if let url = release.url { NSWorkspace.shared.open(url) }
        }
    }

    /// The app runs from `build/` inside the clone it was built from.
    private var clone: URL? {
        let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let isClone = FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/bundle.sh").path)
        return isClone ? root : nil
    }

    private func install(_ release: Release) {
        guard let clone else {
            if let url = release.url { NSWorkspace.shared.open(url) }
            return
        }
        let app = Bundle.main.bundlePath
        // Only a clean clone on main is moved; one with work in progress is the user's to update.
        let script = """
        set -e
        cd "\(clone.path)"
        [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || exit 3
        [ -z "$(git status --porcelain)" ] || exit 3
        git fetch --quiet --tags origin
        git merge --quiet --ff-only "\(release.tag)"
        scripts/bundle.sh >/dev/null
        """
        Task.detached {
            let status = Self.run("/bin/sh", ["-c", script])
            await MainActor.run {
                switch status {
                case 0:
                    // Reopen the rebuilt app once this one has quit.
                    _ = try? Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 1; open \"\(app)\""])
                    NSApp.terminate(nil)
                case 3:
                    self.tell("Update by hand", "The copy at \(clone.path) has changes or isn't on main, so it was left as it is.")
                    if let url = release.url { NSWorkspace.shared.open(url) }
                default:
                    self.tell("The update didn't finish", "Ground Control is unchanged. Running scripts/bundle.sh in \(clone.path) shows what went wrong.")
                }
            }
        }
    }

    private func tell(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// GitHub's latest release: through `gh` first, which is signed in and so sees a private repo,
    /// then plain HTTPS.
    private static func latest() async -> Release? {
        let json: Data? = await Task.detached {
            for gh in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: gh) {
                if let data = output(gh, ["api", "repos/\(repo)/releases/latest"]) { return data }
            }
            return nil
        }.value
        let data: Data?
        if let json {
            data = json
        } else {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            data = try? await URLSession.shared.data(for: request).0
        }
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else { return nil }
        return Release(
            tag: tag,
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            url: (object["html_url"] as? String).flatMap(URL.init(string:)),
            notes: object["body"] as? String ?? ""
        )
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let numbers = { (v: String) in v.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 } }
        let (x, y) = (numbers(a), numbers(b))
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }

    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func output(_ path: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
