import Foundation

/// User-selectable time-limit presets for a Vigil session.
///
/// `.indefinite` means "stay active until explicitly turned off"; every other
/// case carries an exact duration in seconds. The raw values are stable and
/// are part of Vigil's CLI surface (`--duration <preset>`) and on-disk JSON
/// state, so changing them is a breaking change.
public enum Duration: String, CaseIterable, Codable, Identifiable, Sendable {
    case indefinite = "indefinite"
    case m5  = "5m"
    case m10 = "10m"
    case m15 = "15m"
    case m30 = "30m"
    case h1  = "1h"
    case h2  = "2h"
    case h5  = "5h"

    public var id: String { rawValue }

    public var seconds: TimeInterval? {
        switch self {
        case .indefinite: nil
        case .m5:  5 * 60
        case .m10: 10 * 60
        case .m15: 15 * 60
        case .m30: 30 * 60
        case .h1:  60 * 60
        case .h2:  2 * 60 * 60
        case .h5:  5 * 60 * 60
        }
    }

    public var displayName: String {
        switch self {
        case .indefinite: "Indefinitely"
        case .m5:  "5 minutes"
        case .m10: "10 minutes"
        case .m15: "15 minutes"
        case .m30: "30 minutes"
        case .h1:  "1 hour"
        case .h2:  "2 hours"
        case .h5:  "5 hours"
        }
    }

    /// Returns the wall-clock expiry instant for a session that started at
    /// `start`, or `nil` for `.indefinite`.
    public func expiry(from start: Date) -> Date? {
        seconds.map { start.addingTimeInterval($0) }
    }
}
