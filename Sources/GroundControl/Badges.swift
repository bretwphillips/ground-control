import Foundation

enum Badges {
    /// The Dock badge an app shows ("3", "•"), read through lsappinfo, which needs no permission.
    static func read(pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        process.arguments = ["info", "-only", "StatusLabel", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // "StatusLabel"={ "label"="3" }
        let output = String(decoding: data, as: UTF8.self)
        guard let range = output.range(of: #""label"="[^"]*""#, options: .regularExpression) else { return nil }
        let label = output[range].dropFirst(#""label"=""#.count).dropLast()
        return label.isEmpty ? nil : String(label)
    }

    /// Numbers are mentions and DMs; "•" (plain unreads) counts as none.
    static func mentions(_ badge: String?) -> Int {
        Int(badge?.filter(\.isNumber) ?? "") ?? 0
    }
}
