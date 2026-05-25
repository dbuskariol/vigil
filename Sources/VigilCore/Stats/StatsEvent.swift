import Foundation

/// Immutable, append-only event that records a transition in a feature
/// session's lifecycle.
///
/// The stats subsystem is event-sourced: aggregates (lifetime totals,
/// longest-session, etc.) are computed by folding the event log on read.
/// Direct mutation of aggregate counters is deliberately not done — it
/// would let counter drift accumulate silently.
///
/// Events from multiple emitters (CLI's `enable`/`disable` paths in the
/// user-facing CLI process; `HoldEngine`'s auto-expiry / signal paths in
/// the launchd-managed agent process) can race on the log file. The fold
/// de-duplicates `sessionEnded` events by `sessionID` so the FIRST writer
/// wins, making the multi-process emission safe under any ordering.
public enum StatsEvent: Codable, Sendable, Equatable {
    case sessionStarted(SessionStarted)
    case sessionEnded(SessionEnded)

    public static let currentSchemaVersion: Int = 1

    public struct SessionStarted: Codable, Sendable, Equatable {
        public let schemaVersion: Int
        public let sessionID: UUID
        public let feature: Feature
        public let timestamp: Date
        public let duration: Duration

        public init(sessionID: UUID, feature: Feature, timestamp: Date, duration: Duration) {
            self.schemaVersion = StatsEvent.currentSchemaVersion
            self.sessionID = sessionID
            self.feature = feature
            self.timestamp = timestamp
            self.duration = duration
        }
    }

    public struct SessionEnded: Codable, Sendable, Equatable {
        public let schemaVersion: Int
        public let sessionID: UUID
        public let feature: Feature
        public let startedAt: Date
        public let endedAt: Date
        public let endReason: EndReason
        public let elapsedSeconds: TimeInterval
        /// Total time the lid was closed during this session.
        /// Always nil for `.caffeinate`; lid-awake sessions report 0 or more.
        public let lidClosedSeconds: TimeInterval?
        /// Duration of the most recent close-then-open cycle in this session.
        /// nil for `.caffeinate` or if the lid never closed during the session.
        public let lastLidCloseSeconds: TimeInterval?

        public init(
            sessionID: UUID,
            feature: Feature,
            startedAt: Date,
            endedAt: Date,
            endReason: EndReason,
            elapsedSeconds: TimeInterval,
            lidClosedSeconds: TimeInterval?,
            lastLidCloseSeconds: TimeInterval?
        ) {
            self.schemaVersion = StatsEvent.currentSchemaVersion
            self.sessionID = sessionID
            self.feature = feature
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.endReason = endReason
            self.elapsedSeconds = elapsedSeconds
            self.lidClosedSeconds = lidClosedSeconds
            self.lastLidCloseSeconds = lastLidCloseSeconds
        }
    }

    public enum EndReason: String, Codable, Sendable, Equatable {
        /// User explicitly turned the feature off (via popover toggle, CLI,
        /// or "Turn Off All").
        case userDisabled
        /// Session reached its preset duration deadline and auto-disabled.
        case timerExpired
        /// Agent process received SIGTERM/SIGINT with the session still
        /// active — typically a `launchctl bootout` (e.g. Sparkle update)
        /// rather than a user disable (which goes through the CLI's
        /// disable path and emits `.userDisabled`).
        case interrupted
        /// Lid-Awake hit the user-configured battery floor while on battery
        /// power. The agent restores the saved `pmset` profile, releases
        /// assertions, and exits so the Mac can sleep normally instead of
        /// running flat. One-way exit: AC restored afterward does not re-arm.
        case batteryThreshold
        /// Forward-compat sentinel: any raw value this binary does not
        /// recognise decodes to `.unknown` rather than throwing. Without
        /// this, `StatsLog.readAllUnsafe`'s `compactMap { try? ... }`
        /// would silently drop the entire `sessionEnded` event from a
        /// future binary's log line — leaving a permanent dangling
        /// `sessionStarted` and breaking idempotency for that sessionID.
        ///
        /// NEVER emit `.unknown` — it exists only on the read side.
        case unknown

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            self = EndReason(rawValue: raw) ?? .unknown
        }
    }

    public var sessionID: UUID {
        switch self {
        case .sessionStarted(let p): return p.sessionID
        case .sessionEnded(let p): return p.sessionID
        }
    }

    public var feature: Feature {
        switch self {
        case .sessionStarted(let p): return p.feature
        case .sessionEnded(let p): return p.feature
        }
    }

    public var timestamp: Date {
        switch self {
        case .sessionStarted(let p): return p.timestamp
        case .sessionEnded(let p): return p.endedAt
        }
    }
}
