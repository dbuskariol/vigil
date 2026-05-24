import Foundation

/// Per-feature lifetime statistics derived by folding a `[StatsEvent]`.
///
/// All counters are computed on read from immutable events — never
/// mutated in place — so they can't drift from the truth that the log
/// represents.
public struct StatsAggregate: Sendable, Equatable {
    public var perFeature: [Feature: PerFeature]
    public var danglingSessions: [DanglingSession]

    public init(perFeature: [Feature: PerFeature] = [:], danglingSessions: [DanglingSession] = []) {
        self.perFeature = perFeature
        self.danglingSessions = danglingSessions
    }

    public static let empty = StatsAggregate()

    public struct PerFeature: Sendable, Equatable {
        public var sessionCount: Int
        public var totalEnabledSeconds: TimeInterval
        public var totalLidClosedSeconds: TimeInterval
        public var longestSessionSeconds: TimeInterval
        public var lastEnabledAt: Date?
        public var lastEndReason: StatsEvent.EndReason?

        public init(
            sessionCount: Int = 0,
            totalEnabledSeconds: TimeInterval = 0,
            totalLidClosedSeconds: TimeInterval = 0,
            longestSessionSeconds: TimeInterval = 0,
            lastEnabledAt: Date? = nil,
            lastEndReason: StatsEvent.EndReason? = nil
        ) {
            self.sessionCount = sessionCount
            self.totalEnabledSeconds = totalEnabledSeconds
            self.totalLidClosedSeconds = totalLidClosedSeconds
            self.longestSessionSeconds = longestSessionSeconds
            self.lastEnabledAt = lastEnabledAt
            self.lastEndReason = lastEndReason
        }
    }

    /// A `sessionStarted` event with no matching `sessionEnded` in the log.
    /// Typically indicates a crash before the agent could emit its end
    /// event. Surfaced in diagnostics, never counted in aggregates.
    public struct DanglingSession: Sendable, Equatable {
        public let sessionID: UUID
        public let feature: Feature
        public let startedAt: Date
        public let duration: Duration
    }

    /// Pure fold from event log to aggregate. Time-orders events, de-dups
    /// `sessionEnded` by `sessionID` (first wins), and skips
    /// `sessionStarted` events that have no matching ended event.
    public static func fold(events: [StatsEvent]) -> StatsAggregate {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }

        var startsBySessionID: [UUID: StatsEvent.SessionStarted] = [:]
        var endedSessionIDs: Set<UUID> = []
        var perFeature: [Feature: PerFeature] = [:]

        for event in sorted {
            switch event {
            case .sessionStarted(let payload):
                startsBySessionID[payload.sessionID] = payload

            case .sessionEnded(let payload):
                if endedSessionIDs.contains(payload.sessionID) { continue }
                endedSessionIDs.insert(payload.sessionID)

                var pf = perFeature[payload.feature] ?? PerFeature()
                pf.sessionCount += 1
                pf.totalEnabledSeconds += max(0, payload.elapsedSeconds)
                pf.totalLidClosedSeconds += max(0, payload.lidClosedSeconds ?? 0)
                pf.longestSessionSeconds = max(pf.longestSessionSeconds, max(0, payload.elapsedSeconds))
                if pf.lastEnabledAt == nil || payload.startedAt > pf.lastEnabledAt! {
                    pf.lastEnabledAt = payload.startedAt
                    pf.lastEndReason = payload.endReason
                }
                perFeature[payload.feature] = pf
            }
        }

        let dangling = startsBySessionID
            .filter { !endedSessionIDs.contains($0.key) }
            .map { (id, started) in
                DanglingSession(
                    sessionID: id,
                    feature: started.feature,
                    startedAt: started.timestamp,
                    duration: started.duration
                )
            }
            .sorted { $0.startedAt < $1.startedAt }

        return StatsAggregate(perFeature: perFeature, danglingSessions: dangling)
    }
}
