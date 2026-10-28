import AppKit
import CoreAudio
import CoreMediaIO

/// Why an app wants attention.
struct Call {
    enum Kind {
        /// Its badge gained a number.
        case mention
        /// Any badge change, for "every notification".
        case badge
        /// A notification banner, with its text.
        case notification
        /// A terminal that was busy has gone quiet.
        case finished
        /// Played from the menu.
        case preview
    }

    let app: StripApp
    let kind: Kind
    var note: String?
    /// Matched an urgent word or person: comes through even while holding.
    var urgent = false
}

/// Notices deep focus: one app in front for a while, with typing going on. Reads only how long
/// since the last key press, never which keys.
final class FocusWatcher {
    private var front: String?
    private var frontSince = Date()

    var isFocused: Bool {
        let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if current != front {
            front = current
            frontSince = Date()
        }
        let typing = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 15
        return typing && Date().timeIntervalSince(frontSince) > 120
    }
}

/// Notices calls: the microphone or a camera in use by any app. Asks only whether they're running,
/// which needs no permission.
final class MeetingWatcher {
    private(set) var inMeeting = false
    var onChange: ((Bool) -> Void)?

    private var streak = 0
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// Two readings in a row to start (4s) and three to end (6s), so a blip doesn't flip it.
    private func poll() {
        let live = Self.microphoneInUse() || Self.cameraInUse()
        streak = live == inMeeting ? 0 : streak + 1
        guard streak >= (live ? 2 : 3) else { return }
        streak = 0
        inMeeting = live
        log.notice("meeting: \(live)")
        onChange?(live)
    }

    private static func microphoneInUse() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return false
        }
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    private static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return false }
        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for device in devices {
            var running: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }
}

/// Reads notification banners as they appear, through Accessibility, so fly-bys can tell a DM from
/// a newsletter. Text stays in memory and isn't logged.
final class BannerWatcher {
    /// The app a banner came from (matched by name) and its text.
    var onBanner: ((NSRunningApplication, String) -> Void)?

    private var seen: [String: Date] = [:]
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard AXIsProcessTrusted(),
              let center = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            return
        }
        let windows: [AXUIElement] = AX.value(AXUIElementCreateApplication(center.processIdentifier), kAXWindowsAttribute) ?? []
        // A banner's own texts may leave out the app's name, which the window around it has.
        var around: [String: [String]] = [:]
        var banners: [[String]] = []
        for window in windows {
            let all = Self.strings(in: window)
            for banner in Self.banners(in: window) {
                banners.append(banner)
                around[banner.joined(separator: "\n")] = all
            }
        }
        let minuteAgo = Date().addingTimeInterval(-120)
        seen = seen.filter { $0.value > minuteAgo }
        let fresh = banners.filter { seen[$0.joined(separator: "\n")] == nil }
        banners.forEach { seen[$0.joined(separator: "\n")] = Date() }
        // Several at once means Notification Center was opened, which lists old ones.
        guard fresh.count <= 2 else { return }

        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for texts in fresh {
            let named = { (candidates: [String]) in
                running.first { app in
                    candidates.contains { $0.localizedCaseInsensitiveCompare(app.localizedName ?? "\u{0}") == .orderedSame }
                }
            }
            guard let app = named(texts) ?? named(around[texts.joined(separator: "\n")] ?? []) else {
                log.notice("banner from an unknown app")
                continue
            }
            log.notice("banner from \(app.bundleIdentifier ?? "?", privacy: .public)")
            onBanner?(app, texts.joined(separator: " "))
        }
    }

    /// Each banner's texts. A banner is the smallest group holding more than one piece of text.
    private static func banners(in element: AXUIElement, depth: Int = 0) -> [[String]] {
        guard depth < 12 else { return [] }
        let children = AX.children(element)
        let nested = children.flatMap { banners(in: $0, depth: depth + 1) }
        if !nested.isEmpty { return nested }
        let texts = strings(in: element)
        return texts.count >= 2 ? [texts] : []
    }

    private static func strings(in element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        var texts: [String] = []
        for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            if let text: String = AX.value(element, attribute), !text.isEmpty, !texts.contains(text) {
                texts.append(text)
            }
        }
        return texts + AX.children(element).flatMap { strings(in: $0, depth: depth + 1) }
    }
}
