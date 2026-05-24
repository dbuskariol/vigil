import Foundation

/// Reads and writes per-feature `FeatureSession` records.
///
/// The session file is independent of the launchd sentinel file
/// (`Paths.sentinelFile(for:)`); see the note on `Paths.sentinelFile` for
/// why. Sessions are written atomically with ISO-8601 dates and sorted keys
/// so they diff cleanly in source-control-style inspection.
public final class FeatureStateStore {
    public static let shared = FeatureStateStore()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func read(_ feature: Feature) -> FeatureSession? {
        let url = Paths.sessionFile(for: feature)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoder.decode(FeatureSession.self, from: data)
    }

    public func write(_ session: FeatureSession) throws {
        try Paths.ensureAppSupportDirectoryExists()
        let data = try encoder.encode(session)
        try data.write(to: Paths.sessionFile(for: session.feature), options: .atomic)
    }

    public func clear(_ feature: Feature) {
        try? FileManager.default.removeItem(at: Paths.sessionFile(for: feature))
    }

    public func touchSentinel(for feature: Feature) throws {
        try Paths.ensureAppSupportDirectoryExists()
        let url = Paths.sentinelFile(for: feature)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
    }

    public func removeSentinel(for feature: Feature) {
        try? FileManager.default.removeItem(at: Paths.sentinelFile(for: feature))
    }

    public func sentinelExists(for feature: Feature) -> Bool {
        FileManager.default.fileExists(atPath: Paths.sentinelFile(for: feature).path)
    }
}
