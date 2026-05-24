import Foundation

/// Persisted record of an active Vigil session.
///
/// One file per feature lives at `Paths.sessionFile(for:)`. The hold agent
/// reads its own file at launch to schedule expiry; the menu app reads both
/// files to render countdowns and decide whether to re-bootstrap the agents
/// after a Sparkle relaunch.
public struct FeatureSession: Codable, Equatable, Sendable {
    public let feature: Feature
    public let enabledAt: Date
    public let duration: Duration

    public init(feature: Feature, enabledAt: Date, duration: Duration) {
        self.feature = feature
        self.enabledAt = enabledAt
        self.duration = duration
    }

    public var expiresAt: Date? {
        duration.expiry(from: enabledAt)
    }

    public func remainingSeconds(now: Date = Date()) -> Int? {
        expiresAt.map { max(0, Int($0.timeIntervalSince(now))) }
    }

    public func isExpired(now: Date = Date()) -> Bool {
        expiresAt.map { now >= $0 } ?? false
    }
}
