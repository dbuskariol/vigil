import Foundation

/// The set of timed-assertion features Vigil exposes.
///
/// Both features share the same on-disk session shape, the same expiry
/// machinery, and the same status reporting; they differ in (a) which IOKit
/// power assertions they hold while active and (b) whether they apply a
/// privileged `pmset` profile in addition.
public enum Feature: String, CaseIterable, Codable, Identifiable, Sendable {
    case caffeinate
    case lidAwake = "lid-awake"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .caffeinate: "Caffeinate"
        case .lidAwake: "Lid-Awake"
        }
    }
}
