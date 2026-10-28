import Carbon
import Combine

/// Global shortcuts. ⌃⌥1 to ⌃⌥9 open gates by position; the rest are set in Settings. Carbon hot
/// keys need no permission.
final class HotKeys: ObservableObject {
    enum Action {
        case gate(Int)
        case named(ShortcutAction)
    }

    /// Shortcuts another app already holds, so they couldn't be registered.
    @Published private(set) var taken: Set<ShortcutAction> = []

    var onAction: ((Action) -> Void)?

    private let settings: Settings
    private var actions: [UInt32: Action] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var cancellable: AnyCancellable?

    init(settings: Settings) {
        self.settings = settings
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            let keys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            if let action = keys.actions[id.id] { keys.onAction?(action) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        cancellable = settings.$shortcuts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
    }

    /// Paused while a shortcut is being recorded, so pressing one doesn't also run it.
    var paused = false {
        didSet { reload() }
    }

    private func reload() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        guard !paused else { return }

        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, key) in digits.enumerated() {
            register(Shortcut(keyCode: UInt32(key), modifiers: UInt32(controlKey | optionKey), key: ""), .gate(index))
        }
        var taken: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            let shortcut = settings.shortcut(for: action)
            guard !shortcut.isNone else { continue }
            if !register(shortcut, .named(action)) { taken.insert(action) }
        }
        self.taken = taken
    }

    @discardableResult
    private func register(_ shortcut: Shortcut, _ action: Action) -> Bool {
        let number = UInt32(actions.count)
        actions[number] = action
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: OSType(0x4743_5452), id: number),
            GetApplicationEventTarget(), 0, &ref
        )
        if let ref { refs.append(ref) }
        return status == noErr
    }
}
