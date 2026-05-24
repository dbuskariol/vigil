import Foundation

/// Append-only JSONL log of `StatsEvent`s.
///
/// One event per line, ISO-8601 dates, no pretty-printing (each event must
/// be a single line so partial-write recovery is per-line). Writes are
/// `synchronize()`-ed before the file handle is closed, so a power loss
/// at most loses the in-flight event, never corrupts earlier ones.
///
/// `append(_:)` is idempotent for `sessionEnded` events: if the log
/// already contains a `sessionEnded` for the same `sessionID`, the new
/// write is silently dropped. This makes multi-process emission safe
/// without cross-process file locking: the CLI's user-disable path and
/// the agent's signal/expiry paths can both try to emit for the same
/// session, and only the first one persists.
public final class StatsLog {
    public static let shared = StatsLog()

    private let queue = DispatchQueue(label: "com.vigil.app.statslog", qos: .utility)
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        // No `.prettyPrinted`: each event must fit on a single line so the
        // log is line-recoverable after partial writes.
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func append(_ event: StatsEvent) {
        queue.sync { [self] in
            if case .sessionEnded(let payload) = event,
               readAllUnsafe().contains(where: { existing in
                   if case .sessionEnded(let p) = existing { return p.sessionID == payload.sessionID }
                   return false
               }) {
                return
            }
            appendUnsafe(event)
        }
    }

    public func readAll() -> [StatsEvent] {
        queue.sync { readAllUnsafe() }
    }

    public func reset() {
        queue.sync {
            try? FileManager.default.removeItem(at: Paths.statsLogFile)
        }
    }

    // MARK: - Queue-confined internals

    private func appendUnsafe(_ event: StatsEvent) {
        guard let data = try? encoder.encode(event) else {
            fputs("StatsLog: failed to encode event\n", stderr)
            return
        }
        var line = data
        line.append(0x0A) // \n

        let url = Paths.statsLogFile
        do {
            try Paths.ensureAppSupportDirectoryExists()
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
            try handle.close()
        } catch {
            fputs("StatsLog: append failed: \(error)\n", stderr)
        }
    }

    private func readAllUnsafe() -> [StatsEvent] {
        let url = Paths.statsLogFile
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        return data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(StatsEvent.self, from: Data($0)) }
    }
}
