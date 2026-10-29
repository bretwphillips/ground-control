import Foundation
import Security

/// Asks Claude whether a notification is urgent, for ones the urgent words don't catch. Opt-in,
/// with the user's own API key (kept in the Keychain); only the notification's text and app name
/// are sent. Answers are short and fall back to "not urgent" on any failure or after six seconds.
final class UrgencyCheck {
    static let shared = UrgencyCheck()

    private var asked: [String: Date] = [:]

    /// `true` if Claude says it's urgent; `nil` if it couldn't be asked.
    func isUrgent(_ text: String, from app: String) async -> Bool? {
        guard let key = Self.apiKey, !key.isEmpty else { return nil }
        // The same banner can be read more than once while it's on screen.
        let id = app + "\n" + text
        if let last = asked[id], Date().timeIntervalSince(last) < 120 { return nil }
        asked[id] = Date()
        asked = asked.filter { Date().timeIntervalSince($0.value) < 600 }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 6)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // On a policy decline the API answers with its default fallback model instead.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 1024,
            "fallbacks": "default",
            "output_config": [
                "effort": "low",
                "format": [
                    "type": "json_schema",
                    "schema": [
                        "type": "object",
                        "properties": [
                            "urgent": ["type": "boolean"],
                            "reason": ["type": "string"],
                        ],
                        "required": ["urgent", "reason"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "system": """
            You decide whether a notification should interrupt someone in the middle of focused work. \
            Urgent means it needs them now: production problems, someone blocked waiting on them, a \
            direct time-sensitive request, an emergency. Routine chatter, FYIs, newsletters, social \
            messages and anything that can wait an hour are not urgent. When unsure, it isn't urgent.
            """,
            "messages": [["role": "user", "content": "App: \(app)\nNotification: \(text)"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.error("urgency check: no answer")
            return nil
        }
        guard message["stop_reason"] as? String != "refusal",
              let blocks = message["content"] as? [[String: Any]],
              let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let urgent = answer["urgent"] as? Bool else {
            log.error("urgency check: unreadable answer")
            return nil
        }
        log.notice("urgency check: \(app, privacy: .public) \(urgent ? "urgent" : "not urgent", privacy: .public)")
        return urgent
    }

    // MARK: - The API key, in the Keychain

    private static let service = "com.bretwphillips.groundcontrol.anthropic"

    static var apiKey: String? {
        get {
            var item: CFTypeRef?
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
            ]
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(query as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = query
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
