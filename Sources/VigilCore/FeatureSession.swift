import Foundation

/// Persisted record of an active Vigil session.
///
/// One file per feature lives at `Paths.sessionFile(for:)`. The hold agent
/// reads its own file at launch to schedule expiry; the menu app reads both
/// files to render countdowns and decide whether to re-bootstrap the agents
/// after a Sparkle relaunch.
///
/// `id` is a fresh UUID per enable that ties the session to its event-log
/// emissions. It's used by `StatsLog`'s sessionEnded de-dup, so the CLI
/// disable path and the agent's signal/expiry paths can both emit safely.
public struct FeatureSession: Codable, Equatable, Sendable {
    public let id: UUID
    public let feature: Feature
    public let enabledAt: Date
    public let duration: Duration
    /// Lid-Awake battery-floor (0.2.2+). When set and the Mac is on battery,
    /// the hold agent disables the feature once `batteryPercent <= floor`,
    /// restoring the saved `pmset` profile so the Mac can sleep normally
    /// instead of running flat. `nil` means no floor.
    ///
    /// One-way exit: once tripped, plugging AC back in does NOT re-arm.
    /// Lid-Awake only — caffeinate sessions ignore this field even if set.
    ///
    /// Optional + nil-defaulted so on-disk sessions persisted by 0.2.1
    /// continue to decode without migration.
    public let batteryFloorPercent: Int?

    public init(
        id: UUID = UUID(),
        feature: Feature,
        enabledAt: Date,
        duration: Duration,
        batteryFloorPercent: Int? = nil
    ) {
        self.id = id
        self.feature = feature
        self.enabledAt = enabledAt
        self.duration = duration
        self.batteryFloorPercent = batteryFloorPercent
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
