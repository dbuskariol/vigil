import Foundation
import VigilCore

/// Captured `pmset` profile that Lid-Awake snapshots on first enable and
/// restores on disable.
struct StateFile: Codable {
    var createdAt: Date
    var sleepDisabled: Bool?
    var settings: [String: [String: Int]]
}

struct VisualStateFile: Codable {
    var createdAt: Date
    var displayBrightness: [String: Float]
    var keyboardBrightness: Float?
}

struct VisualOptions: Codable, Equatable {
    let dimDisplay: Bool
    let dimKeyboard: Bool

    static func fromCommandLine() -> VisualOptions {
        VisualOptions(
            dimDisplay: !CommandLine.arguments.contains("--no-dim-display"),
            dimKeyboard: !CommandLine.arguments.contains("--no-dim-keyboard")
        )
    }

    static func loadForAssertionAgent() -> VisualOptions {
        guard let data = try? Data(contentsOf: Paths.visualOptionsFile),
              let options = try? JSONDecoder().decode(VisualOptions.self, from: data) else {
            return fromCommandLine()
        }
        return options
    }
}

/// Mutable telemetry for lid-awake: how long the lid has been closed during
/// this session, when it was last closed, etc. Lives in its own file because
/// it is rewritten on every lid open/close event and must NEVER share an
/// inode with the launchd `KeepAlive.PathState` sentinel.
struct LidTelemetry: Codable {
    var enabledAt: Date
    var lidClosedAt: Date?
    var accumulatedLidClosedSeconds: TimeInterval
    var lastClosedSeconds: TimeInterval?

    static func load() -> LidTelemetry? {
        let url = Paths.appSupportDirectory.appendingPathComponent("lid-telemetry.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(LidTelemetry.self, from: data)
    }

    func write() throws {
        try Paths.ensureAppSupportDirectoryExists()
        let url = Paths.appSupportDirectory.appendingPathComponent("lid-telemetry.json")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    static func remove() {
        let url = Paths.appSupportDirectory.appendingPathComponent("lid-telemetry.json")
        try? FileManager.default.removeItem(at: url)
    }
}
